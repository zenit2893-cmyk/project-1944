"""Verify every mission's capture functions against complete original PPC opcodes.

Only analysis artifacts are written. No application config, generated C++, SDK,
source XEX, or game asset is modified. Local reconstructed images remain private.
"""
import argparse
import bisect
import datetime as dt
import hashlib
import importlib.util
import json
import re
import struct
import sys
from pathlib import Path


EXPECTED_GAME = "Call of Duty 3 (USA, Europe)"
EXPECTED_TITLE_ID = "415607E1"
EXPECTED_MEDIA_ID = "2E07093A"
EXPECTED_VERSION_RAW = "0x00000001"
EXPECTED_BASE_VERSION_RAW = "0x00000001"
EXPECTED_CONTAINER = {"encryption_type": 1, "compression_type": 1,
                      "loader_variant": "retail"}
MANIFEST_PATH = Path("analysis/cod3-allmodule-coroutine-manifest.json")

# The capture prologue allocates exactly 400 bytes and preserves the Xenon
# register frame at the offsets below. Keep this table in one place so the
# scanner, report, and negative tests share the same contract.
FRAME_LAYOUT = {
    "bytes": 400,
    "stack_allocation": -400,
    "save_base_register": 1,
    "gpr_offsets": {str(reg): 8 + (reg - 3) * 8 for reg in range(3, 32)},
    "fpr_offsets": {str(reg): 240 + (reg - 14) * 8 for reg in range(14, 32)},
    "cr_offset": 384,
    "lr_offset": 388,
    "ctr_offset": 392,
    "saved_sp_register": 10,
    "saved_sp_global_register": 11,
}


class IdentityMismatch(ValueError):
    """Raised when an input does not belong to the locked COD3 revision."""

    def __init__(self, mismatches):
        self.mismatches = list(mismatches)
        detail = "; ".join(f"{m['field']}: expected {m['expected']!r}, "
                           f"observed {m['observed']!r}" for m in self.mismatches)
        super().__init__(f"COD3 module identity check failed: {detail}")


def hex32(value):
    return f'0x{value & 0xFFFFFFFF:08X}'


def signed16(value):
    return (value & 0x7FFF) - (value & 0x8000)


def lis_addi_address(lis_word, addi_word):
    return (((lis_word & 0xFFFF) << 16) + signed16(addi_word)) & 0xFFFFFFFF


def relocation_pair():
    """Return the only maskable PPC address-load pair used by these bodies."""
    return [(0x3D600000, 0xFFFF0000), (0x396B0000, 0xFFFF0000)]


def core_pattern():
    result = [(0x3D600000, 0xFFFF0000), (0x396B0000, 0xFFFF0000),
              (0x7C2A0B78, 0xFFFFFFFF), (0x914B0000, 0xFFFFFFFF),
              (0x3821FE70, 0xFFFFFFFF)]
    result += [(0xF8000000 | (reg << 21) | (1 << 16) | (8 * (reg - 2)), 0xFFFFFFFF)
               for reg in range(3, 32)]
    result += [(0xD8000000 | (reg << 21) | (1 << 16) | (240 + 8 * (reg - 14)), 0xFFFFFFFF)
               for reg in range(14, 32)]
    result += [(word, 0xFFFFFFFF) for word in
               (0x7C600026, 0x90610180, 0x7C6802A6, 0x90610184, 0x7C6902A6, 0xF8610188)]
    return result


COMMON_SUFFIX_PATTERN = relocation_pair() + [
    (0x816B0000, 0xFFFFFFFF), (0x386BFE70, 0xFFFFFFFF),
    *relocation_pair(), (0x816B0044, 0xFFFFFFFF),
    (0x7D6903A6, 0xFFFFFFFF), (0x4E800421, 0xFFFFFFFF),
    (0x38210190, 0xFFFFFFFF),
]


# The tail starts immediately after the common API68 transfer. A candidate
# is accepted only if one complete variant matches at that exact offset. This
# prevents an unrelated API76/API80/API84 sequence later in a 512-byte window
# from being mistaken for the capture body.
CAPTURE_TAILS = {
    "timed_wait_capture": {
        "api_offset": 76,
        "pattern": relocation_pair() + [(0xC02B0000, 0xFFFFFFFF)] +
                   relocation_pair() + [(0x816B004C, 0xFFFFFFFF),
                                         (0x7D6903A6, 0xFFFFFFFF),
                                         (0x4E800421, 0xFFFFFFFF)],
        "relocation_pair_indices": [0, 3],
        "interface_pair_index": 3,
        "size": 8 * 4,
    },
    "integer_wait_capture": {
        "api_offset": 80,
        "pattern": relocation_pair() + [(0x806B0000, 0xFFFFFFFF)] +
                   relocation_pair() + [(0x816B0050, 0xFFFFFFFF),
                                         (0x7D6903A6, 0xFFFFFFFF),
                                         (0x4E800421, 0xFFFFFFFF)],
        "relocation_pair_indices": [0, 3],
        "interface_pair_index": 3,
        "size": 8 * 4,
    },
    "event_wait_capture": {
        "api_offset": 84,
        "pattern": relocation_pair() + [(0xC02B0000, 0xFFFFFFFF)] +
                   relocation_pair() + [(0x892B0000, 0xFFFFFFFF)] +
                   relocation_pair() + [(0x810B0000, 0xFFFFFFFF)] +
                   relocation_pair() + [(0x80EB0000, 0xFFFFFFFF)] +
                   relocation_pair() + [(0x80CB0000, 0xFFFFFFFF)] +
                   relocation_pair() + [(0x80AB0000, 0xFFFFFFFF)] +
                   relocation_pair() + [(0x808B0000, 0xFFFFFFFF)] +
                   relocation_pair() + [(0x806B0000, 0xFFFFFFFF)] +
                   relocation_pair() + [(0x816B0054, 0xFFFFFFFF),
                                         (0x7D6903A6, 0xFFFFFFFF),
                                         (0x4E800421, 0xFFFFFFFF)],
        "relocation_pair_indices": [0, 3, 6, 9, 12, 15, 18, 21, 24],
        "interface_pair_index": 24,
        "size": 29 * 4,
    },
}


def common_prefix_pattern():
    return core_pattern() + COMMON_SUFFIX_PATTERN


def full_body_relocation_pair_indices(kind):
    """Instruction indices whose low 16 bits are relocatable addresses."""
    tail = CAPTURE_TAILS[kind]
    prefix_words = len(core_pattern()) + len(COMMON_SUFFIX_PATTERN)
    return [0, 58, 62] + [prefix_words + index
                           for index in tail["relocation_pair_indices"]]


def frame_layout_verification(image, offset):
    """Decode and report every frame-store offset in the 58-word prologue."""
    errors = []
    try:
        words = [struct.unpack_from(">I", image, offset + index * 4)[0]
                 for index in range(len(core_pattern()))]
    except struct.error as exc:
        return {"verified": False, "errors": [f"frame prologue is truncated: {exc}"]}

    def check(index, expected, label):
        if words[index] != expected:
            errors.append(f"{label} at instruction {index}: "
                          f"expected {expected:08X}, got {words[index]:08X}")

    check(4, 0x3821FE70, "stack allocation")
    for reg in range(3, 32):
        index = 5 + reg - 3
        expected = 0xF8000000 | (reg << 21) | (1 << 16) | FRAME_LAYOUT["gpr_offsets"][str(reg)]
        check(index, expected, f"GPR r{reg} store")
    for reg in range(14, 32):
        index = 34 + reg - 14
        expected = 0xD8000000 | (reg << 21) | (1 << 16) | FRAME_LAYOUT["fpr_offsets"][str(reg)]
        check(index, expected, f"FPR f{reg} store")
    for index, expected, label in (
        (52, 0x7C600026, "CR move"), (53, 0x90610180, "CR store"),
        (54, 0x7C6802A6, "LR move"), (55, 0x90610184, "LR store"),
        (56, 0x7C6902A6, "CTR move"), (57, 0xF8610188, "CTR store")):
        check(index, expected, label)
    return {
        "verified": not errors,
        "errors": errors,
        "bytes": FRAME_LAYOUT["bytes"],
        "gpr_offsets": FRAME_LAYOUT["gpr_offsets"],
        "fpr_offsets": FRAME_LAYOUT["fpr_offsets"],
        "cr_offset": FRAME_LAYOUT["cr_offset"],
        "lr_offset": FRAME_LAYOUT["lr_offset"],
        "ctr_offset": FRAME_LAYOUT["ctr_offset"],
    }


def verify_pattern(image, offset, pattern):
    if offset < 0 or offset + len(pattern) * 4 > len(image):
        return False
    return all((struct.unpack_from('>I', image, offset + index * 4)[0] & mask) == value
               for index, (value, mask) in enumerate(pattern))


def executable_ranges(pe, image_size=None):
    ranges = []
    for section in pe['sections']:
        if not section['executable']:
            continue
        begin = max(0, section['rva'])
        # A reconstructed image can retain raw bytes after a short virtual
        # size. The scanner may inspect only bytes that are actually present.
        length = max(section['virtual_size'], section.get('raw_size', 0))
        end = min(begin + length, 0x100000000)
        if image_size is not None:
            end = min(end, image_size)
        if begin < end:
            ranges.append((begin, end))
    return ranges


def address_in_image(pe, image_size, address, size=4):
    base = int(pe['base'], 16)
    offset = address - base
    return 0 <= offset and offset + size <= image_size


def address_in_writable_section(pe, address, size=4):
    base = int(pe['base'], 16)
    offset = address - base
    for section in pe['sections']:
        begin = section['rva']
        end = begin + max(section['virtual_size'], section.get('raw_size', 0))
        if begin <= offset and offset + size <= end:
            return bool(int(section['flags'], 16) & 0x80000000)
    return False


def parse_hex(value):
    if isinstance(value, int):
        return value
    if not isinstance(value, str):
        raise ValueError(f"expected hexadecimal string, got {value!r}")
    return int(value, 0)


def load_manifest(root):
    path = root / MANIFEST_PATH
    manifest = json.loads(path.read_text(encoding='utf-8'))
    if manifest.get('schema_version') != 1:
        raise ValueError(f"unsupported coroutine manifest schema in {path}")
    modules = manifest.get('modules')
    if not isinstance(modules, list) or len(modules) != 15:
        raise ValueError("coroutine manifest must contain exactly 15 mission modules")
    names = [entry.get('module') for entry in modules]
    if len(set(names)) != len(names) or any(not name for name in names):
        raise ValueError("coroutine manifest module names must be unique")
    return manifest


def identity_mismatches(root, xex, metadata, pe, expected, image_sha256=None,
                        reconstruction=None, loader_source_sha256=None):
    """Return all identity mismatches without attempting to interpret code."""
    mismatches = []

    def check(field, observed, expected_value):
        if observed != expected_value:
            mismatches.append({'field': field, 'expected': expected_value,
                               'observed': observed})

    relative_path = xex.relative_to(root).as_posix()
    check('module_path', relative_path, expected['path'])
    check('module_name', xex.stem, expected['module'])
    source_sha256 = hashlib.sha256(xex.read_bytes()).hexdigest().upper()
    check('source_sha256', source_sha256, expected['source_sha256'])

    execution = metadata.get('execution_info', {})
    check('title_id', execution.get('title_id'),
          root_manifest_value(root, 'title_id'))
    check('media_id', execution.get('media_id'),
          root_manifest_value(root, 'media_id'))
    check('version_raw', execution.get('version', {}).get('raw'),
          root_manifest_value(root, 'version_raw'))
    check('base_version_raw', execution.get('base_version', {}).get('raw'),
          root_manifest_value(root, 'base_version_raw'))
    check('platform', execution.get('platform'), root_manifest_value(root, 'platform'))
    check('disc_number', execution.get('disc_number'), root_manifest_value(root, 'disc_number'))
    check('disc_count', execution.get('disc_count'), root_manifest_value(root, 'disc_count'))
    check('original_pe_name', metadata.get('original_pe_name'), expected['original_pe_name'])

    check('xex_image_base', metadata.get('image_base'), expected['image_base'])
    check('pe_image_base', pe.get('base'), expected['image_base'])
    check('xex_entry_point', metadata.get('entry_point'), expected['entry_point'])
    check('pe_entry_point', pe.get('entry_point'), expected['entry_point'])
    file_format = metadata.get('file_format', {})
    container = root_manifest_value(root, 'container')
    check('encryption_type', file_format.get('encryption_type'), container['encryption_type'])
    check('compression_type', file_format.get('compression_type'), container['compression_type'])
    if reconstruction is not None:
        check('loader_variant', reconstruction.get('loader_variant'), container['loader_variant'])
        check('reconstruction_encryption', reconstruction.get('encryption'), container['encryption_type'])
        check('reconstruction_compression', reconstruction.get('compression'), container['compression_type'])
    if loader_source_sha256 is not None:
        check('loader_source_sha256', loader_source_sha256,
              root_manifest_value(root, 'loader_source_sha256'))
    if image_sha256 is not None:
        check('image_sha256', image_sha256, expected['image_sha256'])
    return mismatches


def root_manifest_value(root, key):
    """Read one top-level lock value for pure identity-test friendliness."""
    manifest = json.loads((root / MANIFEST_PATH).read_text(encoding='utf-8'))
    return manifest[key]


def validate_module_identity(root, xex, metadata, pe, expected, image,
                             reconstruction=None, loader_source_sha256=None):
    image_sha256 = hashlib.sha256(image).hexdigest().upper()
    mismatches = identity_mismatches(
        root, xex, metadata, pe, expected, image_sha256=image_sha256,
        reconstruction=reconstruction, loader_source_sha256=loader_source_sha256)
    # image_size is a property of the reconstructed image, not inspect_pe().
    if len(image) != expected.get('image_size'):
        mismatches.append({'field': 'image_size', 'expected': expected.get('image_size'),
                           'observed': len(image)})
    if mismatches:
        raise IdentityMismatch(mismatches)
    return {
        'module': expected['module'], 'path': expected['path'],
        'original_pe_name': expected['original_pe_name'],
        'title_id': root_manifest_value(root, 'title_id'),
        'media_id': root_manifest_value(root, 'media_id'),
        'version_raw': root_manifest_value(root, 'version_raw'),
        'base_version_raw': root_manifest_value(root, 'base_version_raw'),
        'platform': root_manifest_value(root, 'platform'),
        'disc_number': root_manifest_value(root, 'disc_number'),
        'disc_count': root_manifest_value(root, 'disc_count'),
        'source_sha256': hashlib.sha256(xex.read_bytes()).hexdigest().upper(),
        'image_sha256': image_sha256, 'image_base': pe['base'],
        'entry_point': pe['entry_point'], 'image_size': len(image),
        'source_hash_verified': True, 'image_hash_verified': True,
        'revision_verified': True,
    }


def range_contains(ranges, begin, end):
    return any(start <= begin and end <= stop for start, stop in ranges)


def ppc_branch_target(base, offset, word):
    """Decode an I-form PPC branch-with-link target and continuation."""
    displacement = word & 0x03FFFFFC
    if displacement & 0x02000000:
        displacement -= 0x04000000
    target = ((0 if word & 2 else base + offset) + displacement) & 0xFFFFFFFF
    return target, base + offset + 4


def _reject(rejected, base, offset, reason, **extra):
    entry = {'address': hex32(base + offset), 'reason': reason}
    entry.update(extra)
    rejected.append(entry)


def match_capture_at(image, pe, offset, ranges):
    """Match one complete capture body at an aligned executable offset."""
    base = int(pe['base'], 16)
    prefix = common_prefix_pattern()
    core = core_pattern()
    if offset % 4 or not range_contains(ranges, offset, offset + 4):
        return None, 'candidate is not aligned or executable'
    if not range_contains(ranges, offset, offset + len(prefix) * 4):
        return None, 'candidate prologue extends outside an executable section'
    if not verify_pattern(image, offset, core):
        return None, 'Full 400-byte frame save opcode pattern differs'
    frame = frame_layout_verification(image, offset)
    if not frame['verified']:
        return None, 'frame offset contract differs'
    suffix_offset = offset + len(core) * 4
    if not verify_pattern(image, suffix_offset, COMMON_SUFFIX_PATTERN):
        return None, 'Frame source / API68 / stack restoration suffix differs'
    prefix_words = struct.unpack_from('>II', image, offset)
    scratch_address = lis_addi_address(*prefix_words)
    suffix_words = struct.unpack_from('>10I', image, suffix_offset)
    suffix_scratch = lis_addi_address(*suffix_words[:2])
    interface_address = lis_addi_address(*suffix_words[4:6])
    if suffix_scratch != scratch_address:
        return None, 'Saved original-SP global differs between store and reload'
    if not address_in_image(pe, len(image), scratch_address) or not address_in_writable_section(pe, scratch_address):
        return None, 'Saved original-SP global is outside writable image data'
    if not address_in_image(pe, len(image), interface_address) or not address_in_writable_section(pe, interface_address):
        return None, 'Module interface is outside writable image data'
    if interface_address != (scratch_address + 0x4C) & 0xFFFFFFFF:
        return None, 'Module interface is not saved-SP global plus 0x4C'

    tail_offset = suffix_offset + len(COMMON_SUFFIX_PATTERN) * 4
    matches = []
    for kind, spec in CAPTURE_TAILS.items():
        pattern = spec['pattern']
        end_offset = tail_offset + len(pattern) * 4
        if not range_contains(ranges, tail_offset, end_offset):
            continue
        if not verify_pattern(image, tail_offset, pattern):
            continue
        pairs = {}
        for pair_index in spec['relocation_pair_indices']:
            pair_words = struct.unpack_from('>II', image, tail_offset + pair_index * 4)
            address = lis_addi_address(*pair_words)
            pairs[pair_index] = hex32(address)
            if not address_in_image(pe, len(image), address) or not address_in_writable_section(pe, address):
                return None, f'{kind} relocation address at tail instruction {pair_index} is outside writable image data'
        interface_pair = spec['interface_pair_index']
        if pairs[interface_pair] != hex32(interface_address):
            return None, f'{kind} wait API uses an unexpected interface pointer'
        next_word = 0
        if end_offset + 4 <= len(image):
            next_word = struct.unpack_from('>I', image, end_offset)[0]
        next_is_capture = verify_pattern(image, end_offset, core)
        if next_word != 0 and not next_is_capture:
            return None, 'Terminal API call is not followed by padding or the next complete capture function'
        full_indices = full_body_relocation_pair_indices(kind)
        matches.append({
            'kind': kind, 'address': hex32(base + offset),
            'size': end_offset - offset,
            'end_exclusive': hex32(base + end_offset),
            'body_sha256': hashlib.sha256(image[offset:end_offset]).hexdigest().upper(),
            'save_core_instructions': len(core), 'save_core_masked_indices': [0, 1],
            'saved_sp_global': hex32(scratch_address),
            'module_interface': hex32(interface_address),
            'save_api_byte_offset': 68,
            'save_api_call': hex32(base + suffix_offset + 8 * 4),
            'save_api_word': '4E800421',
            'wait_api_byte_offset': spec['api_offset'],
            'wait_api_call': hex32(base + tail_offset + (len(pattern) - 1) * 4),
            'wait_api_word': '4E800421',
            'following_word': f'{next_word:08X}',
            'following_is_complete_capture': next_is_capture,
            'frame_layout_verified': True,
            'frame_layout': frame,
            'relocation_mask_instruction_indices': full_indices,
            'relocation_pair_count': len(full_indices),
            'tail_relocation_pairs': pairs,
            'exact_variant_instruction_count': len(core) + len(COMMON_SUFFIX_PATTERN) + len(pattern),
            'exact_variant_verified': True,
            'terminal_boundary_verified': True,
            'caller_examples': [], 'direct_caller_count': 0,
            'direct_caller_addresses': [],
            'verification': 'complete original frame, exact variant tail, same saved-SP global, same module interface, final API76/80/84 call, and following boundary verified',
        })
    if not matches:
        return None, 'no exact timed/integer/event capture tail at the immediate body boundary'
    return matches, None


def scan_capture_candidates(image, pe):
    """Return complete candidates plus explicit rejection/ambiguity evidence."""
    ranges = executable_ranges(pe, len(image))
    base = int(pe['base'], 16)
    anchor = struct.pack('>III', 0x7C2A0B78, 0x914B0000, 0x3821FE70)
    found = []
    rejected = []
    cursor = 0
    while True:
        hit = image.find(anchor, cursor)
        if hit < 0:
            break
        cursor = hit + 4
        offset = hit - 8
        matches, reason = match_capture_at(image, pe, offset, ranges)
        if matches:
            found.extend(matches)
        elif reason:
            _reject(rejected, base, offset, reason)
    by_kind = {}
    for entry in found:
        by_kind.setdefault(entry['kind'], []).append(entry)
    ambiguous = {}
    for kind, entries in by_kind.items():
        if len(entries) > 1:
            addresses = [entry['address'] for entry in entries]
            ambiguous[kind] = addresses
            rejected.append({'kind': kind, 'reason': 'Ambiguous complete capture signature',
                             'addresses': addresses})
    kinds = set(by_kind)
    status = 'verified' if len(found) == 3 and kinds == set(CAPTURE_TAILS) and not rejected else 'needs_manual_review'
    return {
        'captures': found, 'rejected_or_ambiguous_candidates': rejected,
        'candidate_count': len(found), 'candidate_kind_counts': {
            kind: len(by_kind.get(kind, [])) for kind in CAPTURE_TAILS},
        'ambiguous_kinds': ambiguous, 'status': status,
        'executable_ranges': [{'begin': begin, 'end_exclusive': end}
                              for begin, end in ranges],
    }


def attach_direct_callers(image, pe, captures, registered):
    """Resolve every direct PPC `bl` to a capture and record its continuation."""
    base = int(pe['base'], 16)
    ranges = executable_ranges(pe, len(image))
    lookup = {int(entry['address'], 16): entry for entry in captures}
    for begin, end in ranges:
        for offset in range(begin, end & ~3, 4):
            word = struct.unpack_from('>I', image, offset)[0]
            if word >> 26 != 18 or not word & 1:
                continue
            target, continuation = ppc_branch_target(base, offset, word)
            entry = lookup.get(target)
            if entry is None:
                continue
            if continuation in entry['direct_caller_addresses']:
                continue
            entry['direct_caller_addresses'].append(continuation)
            entry['direct_caller_count'] = len(entry['direct_caller_addresses'])
            if len(entry['caller_examples']) < 6:
                pos = bisect.bisect_right(registered, base + offset)
                entry['caller_examples'].append({
                    'call_address': hex32(base + offset),
                    'call_word': f'{word:08X}',
                    'branch_target': hex32(target),
                    'saved_continuation_lr': hex32(continuation),
                    'continuation_address': hex32(continuation),
                    'nearest_preceding_registered_entry': hex32(registered[pos - 1]) if pos else None,
                })
    for entry in captures:
        entry['direct_caller_addresses'] = [hex32(address) for address in
                                            sorted(entry['direct_caller_addresses'])]
        entry['continuation_callers_verified'] = bool(entry['direct_caller_count']) and all(
            int(item['saved_continuation_lr'], 16) == int(item['call_address'], 16) + 4
            for item in entry['caller_examples'])


def verify_module(root, xex, loader, xex_analyzer, image_dir, manifest, expected, before_codegen=False):
    image, reconstruction = loader.reconstruct(xex, sdk_source_root(root))
    pe = loader.inspect_pe(image)
    metadata = xex_analyzer.analyze(xex)
    loader_source_sha256 = reconstruction.get('public_loader_source_sha256')
    identity = validate_module_identity(
        root, xex, metadata, pe, expected, image,
        reconstruction=reconstruction, loader_source_sha256=loader_source_sha256)
    base = int(pe['base'], 16)
    image_dir.mkdir(exist_ok=True)
    image_path = image_dir / f"{expected['module']}.bin"
    image_path.write_bytes(image)
    registered_file = root / f"cod3-pc/generated/{expected['module']}/cod3_pc_register.cpp"
    registered_text = registered_file.read_text(encoding='utf-8') if registered_file.exists() else ''
    registered = sorted(set(int(v, 16) for v in re.findall(
        r'SetFunction\(0x([0-9A-Fa-f]+)', registered_text)))

    # A fresh install builds this map before the first code generation (the
    # PCH overlay made from it is an input to codegen), so there is no ReXGlue
    # output to check yet. The instruction-level checks below still run in
    # full; registration is then confirmed by a second run after codegen.
    registration_checked = registered_file.exists() or not before_codegen

    scan = scan_capture_candidates(image, pe)
    captures = scan['captures']
    for capture in captures:
        capture['registered_in_existing_rex_output'] = (
            int(capture['address'], 16) in registered if registration_checked else None)
    attach_direct_callers(image, pe, captures, registered)
    status = 'verified' if (scan['status'] == 'verified' and
                            all((entry['registered_in_existing_rex_output'] or not registration_checked) and
                                entry['continuation_callers_verified']
                                for entry in captures)) else 'needs_manual_review'
    return {
        'module': expected['module'], 'module_name': expected['module'],
        'guest_path': xex.relative_to(root / 'game/cod3').as_posix(),
        'input_xex': xex.relative_to(root).as_posix(),
        'input_sha256': identity['source_sha256'],
        'input_sha256_verified': identity['source_hash_verified'],
        'original_pe_name': expected['original_pe_name'],
        'image_path': image_path.relative_to(root).as_posix(),
        'image_sha256': identity['image_sha256'],
        'image_sha256_verified': identity['image_hash_verified'],
        'image_base': hex32(base), 'image_size': len(image),
        'entry_point': pe['entry_point'], 'reconstruction': reconstruction,
        'identity': identity,
        'registration_source': registered_file.relative_to(root).as_posix(),
        'registration_sha256': hashlib.sha256(registered_text.encode()).hexdigest().upper() if registered_text else None,
        'registration_checked': registration_checked,
        'status': status, 'capture_count': len(captures), 'captures': captures,
        'candidate_scan': {k: v for k, v in scan.items() if k != 'captures'},
        'rejected_or_ambiguous_candidates': scan['rejected_or_ambiguous_candidates'],
    }


def compare_capture_body(actual_words, reference_words, kind,
                         actual_interface, reference_interface):
    """Compare a body with explicit relocation masks and layout relationships."""
    expected_pairs = full_body_relocation_pair_indices(kind)
    masks = [0xFFFFFFFF] * len(reference_words)
    for index in expected_pairs:
        if index + 1 < len(masks):
            masks[index] = masks[index + 1] = 0xFFFF0000
    opcode_mismatches = []
    layout_mismatches = []
    relocation_masks = []
    if len(actual_words) != len(reference_words):
        opcode_mismatches.append('Function size differs from independently located reference variant')
    else:
        for index, (actual, expected, mask) in enumerate(zip(actual_words, reference_words, masks)):
            if actual & mask != expected & mask:
                opcode_mismatches.append(f'Opcode mismatch at instruction {index}')
        actual_pairs = [index for index in range(len(actual_words) - 1)
                        if actual_words[index] & 0xFFFF0000 == 0x3D600000 and
                        actual_words[index + 1] & 0xFFFF0000 == 0x396B0000]
        if actual_pairs != expected_pairs:
            opcode_mismatches.append(
                f'Relocation pair positions differ: expected {expected_pairs}, got {actual_pairs}')
        for index in expected_pairs:
            if index + 1 >= len(actual_words) or index + 1 >= len(reference_words):
                continue
            expected_address = lis_addi_address(*reference_words[index:index + 2])
            actual_address = lis_addi_address(*actual_words[index:index + 2])
            expected_delta = (expected_address - reference_interface) & 0xFFFFFFFF
            actual_delta = (actual_address - actual_interface) & 0xFFFFFFFF
            matches = actual_delta == expected_delta
            relocation_masks.append({
                'instruction_indices': [index, index + 1],
                'mask': '0xFFFF0000',
                'expected_address': hex32(expected_address),
                'actual_address': hex32(actual_address),
                'expected_delta_from_module_interface': hex32(expected_delta),
                'actual_delta_from_module_interface': hex32(actual_delta),
                'relative_delta_matches': matches,
            })
            if not matches:
                layout_mismatches.append(
                    f'Module-global relationship differs at instruction {index}')
    mismatch = opcode_mismatches + layout_mismatches
    return {
        'instruction_count': len(reference_words),
        'masked_immediate_instruction_indices': [index + delta for index in expected_pairs
                                                 for delta in (0, 1)],
        'relocated_address_pair_count': len(expected_pairs),
        'relocation_masks': relocation_masks,
        'relative_global_layout_matches': not layout_mismatches,
        'all_non_address_bits_match': not opcode_mismatches,
        'mismatches': mismatch,
    }


def verify_full_bodies(root, modules):
    """Compare every instruction with Saint-Lo and the independent body grammar."""
    reference = next(module for module in modules if module['module'] == 'saint_lo')
    reference_image = (root / reference['image_path']).read_bytes()
    reference_base = int(reference['image_base'], 16)
    references = {entry['kind']: entry for entry in reference['captures']}
    for kind, spec in CAPTURE_TAILS.items():
        canonical = references.get(kind)
        if canonical is None:
            reference['status'] = 'needs_manual_review'
            reference['rejected_or_ambiguous_candidates'].append(
                {'reason': f'Missing canonical {kind} capture in Saint-Lo'})
            continue
        reference_offset = int(canonical['address'], 16) - reference_base
        static_pattern = common_prefix_pattern() + spec['pattern']
        if not verify_pattern(reference_image, reference_offset, static_pattern):
            reference['status'] = 'needs_manual_review'
            reference['rejected_or_ambiguous_candidates'].append(
                {'address': canonical['address'],
                 'reason': f'Saint-Lo {kind} body fails independent exact variant grammar'})
    for module in modules:
        image = (root / module['image_path']).read_bytes()
        base = int(module['image_base'], 16)
        for capture in module['captures']:
            canonical = references[capture['kind']]
            reference_offset = int(canonical['address'], 16) - reference_base
            offset = int(capture['address'], 16) - base
            reference_words = list(struct.unpack_from(
                f">{canonical['size'] // 4}I", reference_image, reference_offset))
            actual_words = list(struct.unpack_from(
                f">{capture['size'] // 4}I", image, offset))
            comparison = compare_capture_body(
                actual_words, reference_words, capture['kind'],
                int(capture['module_interface'], 16),
                int(canonical['module_interface'], 16))
            comparison.update({
                'reference_module': 'saint_lo',
                'reference_address': canonical['address'],
                'exact_variant_grammar_matches': verify_pattern(
                    image, offset, common_prefix_pattern() + CAPTURE_TAILS[capture['kind']]['pattern']),
            })
            capture['full_body_verification'] = comparison
            if comparison['mismatches'] or not comparison['exact_variant_grammar_matches']:
                module['status'] = 'needs_manual_review'
                module['rejected_or_ambiguous_candidates'].append({
                    'address': capture['address'], 'reason': comparison['mismatches'] or
                    ['Exact variant grammar mismatch']})


def sdk_source_root(root):
    """The ReXGlue SDK source: tools/rexglue-source in the workspace,
    sdk-source in a released package. Same files either way, so the locked
    loader-source hash still identifies it."""
    for candidate in ('tools/rexglue-source', 'sdk-source'):
        path = root / candidate
        if (path / 'src/system/xex_module.cpp').is_file():
            return path
    raise FileNotFoundError('ReXGlue SDK source not found under tools/rexglue-source or sdk-source')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--before-codegen', action='store_true',
                        help='Accept modules that have no ReXGlue output yet; every instruction-level check '
                             'still applies, and registration is left for the run after code generation.')
    args = parser.parse_args()
    root = args.workspace.resolve()
    manifest = load_manifest(root)
    expected_by_path = {entry['path']: entry for entry in manifest['modules']}
    sys.path.insert(0, str(root / 'analysis/title-python'))
    spec = importlib.util.spec_from_file_location('cod3_xex_reconstruction', root / 'scripts/analyze-title-image.py')
    loader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loader)
    xex_spec = importlib.util.spec_from_file_location('cod3_xex_headers', root / 'scripts/analyze-title-xex.py')
    xex_analyzer = importlib.util.module_from_spec(xex_spec)
    xex_spec.loader.exec_module(xex_analyzer)
    module_paths = sorted((root / 'game/cod3/sp').glob('*/*.dll'))
    actual_paths = {path.relative_to(root).as_posix() for path in module_paths}
    if actual_paths != set(expected_by_path):
        raise ValueError('COD3 mission module set differs from the locked 15-module manifest')
    loader_source = sdk_source_root(root) / 'src/system/xex_module.cpp'
    loader_source_sha256 = hashlib.sha256(loader_source.read_bytes()).hexdigest().upper()
    if loader_source_sha256 != manifest['loader_source_sha256']:
        raise ValueError('ReXGlue loader source hash differs from the locked reconstruction source')
    image_dir = root / 'analysis/cod3-coroutine-module-images'
    image_dir.mkdir(exist_ok=True)
    modules = []
    for xex in module_paths:
        relative = xex.relative_to(root).as_posix()
        module = verify_module(root, xex, loader, xex_analyzer, image_dir,
                               manifest, expected_by_path[relative], args.before_codegen)
        modules.append(module)
        print(module['module'], module['status'], ', '.join(f"{c['address']}+{c['size']}:{c['kind']}" for c in module['captures']))
    verify_full_bodies(root, modules)
    print(f"Full-function relocation verification: {sum(m['status'] == 'verified' for m in modules)}/{len(modules)} modules")
    report = {
        'schema_version': 2, 'analyzed_utc': dt.datetime.now(dt.timezone.utc).isoformat(),
        'script': 'analysis/cod3-allmodule-coroutine-sites.py',
        'script_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest().upper(),
        'manifest': 'analysis/cod3-allmodule-coroutine-manifest.json',
        'manifest_sha256': hashlib.sha256((root / MANIFEST_PATH).read_bytes()).hexdigest().upper(),
        'game': manifest['game'], 'title_id': manifest['title_id'],
        'media_id': manifest['media_id'], 'version_raw': manifest['version_raw'],
        'base_version_raw': manifest['base_version_raw'],
        'platform': manifest['platform'], 'disc_number': manifest['disc_number'],
        'disc_count': manifest['disc_count'],
        'loader_source_sha256': loader_source_sha256,
        'module_count': len(modules),
        'verified_module_count': sum(m['status'] == 'verified' for m in modules),
        'registration_checked': all(m['registration_checked'] for m in modules),
        'capture_count': sum(m['capture_count'] for m in modules),
        'scope': 'Original instruction verification only; bridge installation and gameplay tests for these modules are separate.',
        'mask_policy': 'Only consecutive lis r11 / addi r11,r11 pairs at the explicitly listed relocation indices have low immediate fields masked. Every other instruction bit of each exact body must match the Saint-Lo reference and the independent timed/integer/event grammar. Each relocated address must retain the same displacement from the module interface.',
        'saved_frame': {**FRAME_LAYOUT,
                        'r10_saved_value': 'entry guest SP',
                        'r11_saved_value': 'sign-extended module saved-SP global address',
                        'resume_does_not_load_saved_cr': True},
        'variant_contracts': {
            kind: {'api_byte_offset': spec['api_offset'],
                   'instruction_count': len(core_pattern()) + len(COMMON_SUFFIX_PATTERN) + len(spec['pattern']),
                   'relocation_pair_indices': full_body_relocation_pair_indices(kind),
                   'tail_relocation_pair_indices': spec['relocation_pair_indices']}
            for kind, spec in CAPTURE_TAILS.items()},
        'modules': modules,
    }
    (root / 'analysis/cod3-allmodule-coroutine-sites.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    rows = ['# Verified capture functions for all COD3 mission modules', '',
            'Every address below is recovered from that module\'s own reconstructed original image. '
            'The locked USA/Europe title, media ID, version, module names, PE names, image bases, '
            'source hashes, and reconstructed image hashes are checked before code scanning. '
            'These are static verification results; gameplay and bridge integration remain separate.', '',
            '| Guest module | Timed capture | Size | Integer capture | Size | Event capture | Size | Status |',
            '| --- | --- | ---: | --- | ---: | --- | ---: | --- |']
    for module in modules:
        timed = next((c for c in module['captures'] if c['kind'] == 'timed_wait_capture'), {})
        integer = next((c for c in module['captures'] if c['kind'] == 'integer_wait_capture'), {})
        event = next((c for c in module['captures'] if c['kind'] == 'event_wait_capture'), {})
        rows.append(f"| `{module['guest_path']}` | `{timed.get('address', '?')}` | {timed.get('size', '?')} | `{integer.get('address', '?')}` | {integer.get('size', '?')} | `{event.get('address', '?')}` | {event.get('size', '?')} | {module['status']} |")
    rows += ['', 'The JSON companion records each XEX/image/body hash, module identity fields, module '
             'interface and saved-SP globals, exact variant contract, relocation masks and deltas, '
             'direct caller examples with continuation LR, and every rejected or ambiguous candidate.', '',
             'Each body must match one exact variant: timed API76 (76 instructions / 304 bytes), integer '
             'API80 (76 instructions / 304 bytes), or event API84 (97 instructions / 388 bytes). The '
             'common prologue saves the complete 400-byte frame: GPR3..31 at offsets 8..232, FPR14..31 '
             'at 240..376, CR at 384, LR at 388, and CTR at 392. The suffix reloads the same saved-SP '
             'global, calls API68 through the same module interface, and restores SP before the exact '
             'variant tail.', '',
             'Only consecutive `lis r11` / `addi r11,r11` pairs listed in JSON have low immediate fields '
             'masked. Every other instruction bit must match the independently located Saint-Lo body, '
             'and every relocated address must retain the same displacement from the module interface. '
             'A duplicate complete signature is reported as ambiguous and cannot reach `verified`.', '',
             'The saved LR is the capture caller\'s continuation. Each recorded direct PPC `bl` target '
             'and continuation address is checked statically; this does not claim live gameplay coverage. '
             'The r10/r11 and CR caveats in `cod3-scheduler-transfer-contracts.md` apply to every match.', '',
             'No application configuration, generated C++, or input XEX was modified. Reconstructed '
             'images under `analysis/cod3-coroutine-module-images` are private, local game-derived artifacts.']
    (root / 'analysis/cod3-allmodule-coroutine-sites.md').write_text('\n'.join(rows) + '\n', encoding='utf-8')
    if len(modules) != 15 or any(m['status'] != 'verified' for m in modules):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
