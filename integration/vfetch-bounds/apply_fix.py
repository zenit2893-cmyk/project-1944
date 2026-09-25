"""Restore the vertex-fetch bounds mask in an isolated ReXGlue source stage.

Problem: the pinned ReXGlue DXBC translator loads vertex words from shared
memory without checking the fetch constant's buffer size (its own comment still
says bound checking is not done). The Xbox 360 returns zeros for words at or
past the end of the fetch buffer, and Call of Duty 3 relies on that: its grass
draws more vertices than the buffer holds and expects the extra ones to collapse
into degenerate primitives. Without the check they read unrelated guest memory
and stretch into long streaks across the field.

The replacement code is the bounds/word-mask sequence from the local Xenia
reference tree (tools/Xenia-source/src/xenia/gpu/dxbc_shader_translator_fetch.cc,
"Words at or past the end of the fetch buffer must read as 0").

This script never edits tools/rexglue-source or the installed SDK. It stages a
copy and rewrites exactly two anchored regions, refusing to run if either anchor
does not match the pinned text.
"""
import hashlib
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def _find_sdk_source():
    """Locate the pinned ReXGlue source.

    The workspace keeps a dedicated worktree for the runtime build; a released
    package ships the same source as sdk-source/ so the plugin can be rebuilt
    there too. Either is fine - the patch is anchored on file contents, not on
    a path.
    """
    for candidate in ('integration/rexglue-runtime-build/src', 'sdk-source'):
        path = ROOT / candidate
        if (path / REL).is_file():
            return path
    return ROOT / 'integration/rexglue-runtime-build/src'


REL = 'src/graphics/pipeline/shader/dxbc_translator_fetch.cpp'
SOURCE = _find_sdk_source()
STAGE = Path(__file__).resolve().parent / 'source'
# Reference only: its hash goes into the receipt to record what the restored
# code was compared against. Packages do not carry the Xenia checkout.
XENIA = ROOT / 'tools/Xenia-source/src/xenia/gpu/dxbc_shader_translator_fetch.cc'

ANCHOR_1 = """  // - Load needed words to system_temp_result_, words 0, 1, 2, 3 to X, Y, Z, W
  //   respectively.

  // FIXME(Triang3l): Bound checking is not done here, but haven't encountered
  // any games relying on out-of-bounds access. On Adreno 200 on Android (LG
  // P705), however, words (not full elements) out of glBufferData bounds
  // contain 0.
"""

REPLACE_1 = """  // Words at or past the end of the fetch buffer must read as 0. The shared
  // memory binding covers all of physical memory, so a word out of bounds
  // would load unrelated guest data where the hardware returns zeros. Games
  // rely on that: an overallocated draw expects the vertices it never wrote to
  // collapse into degenerate primitives (Call of Duty 3 grass). Compute the
  // exclusive end of the buffer in bytes from the fetch constant and a mask of
  // which words of the element fall inside it. Restored from the Xenia
  // reference implementation.
  uint32_t bounds_temp = PushSystemTemp(0, 2);
  uint32_t word_mask_temp = bounds_temp + 1;
  // bounds_temp.x = buffer size in words (bits 2:25 of the second fetch
  // constant word).
  a_.OpUBFE(dxbc::Dest::R(bounds_temp, 0b0001), dxbc::Src::LU(24), dxbc::Src::LU(2),
            fetch_constant_src.SelectFromSwizzled(1));
  // bounds_temp.y = base address of the buffer in bytes.
  a_.OpAnd(dxbc::Dest::R(bounds_temp, 0b0010), fetch_constant_src.SelectFromSwizzled(0),
           dxbc::Src::LU(~uint32_t(3)));
  // bounds_temp.x = exclusive end of the buffer in bytes.
  a_.OpUMAd(dxbc::Dest::R(bounds_temp, 0b0001), dxbc::Src::R(bounds_temp, dxbc::Src::kXXXX),
            dxbc::Src::LU(4), dxbc::Src::R(bounds_temp, dxbc::Src::kYYYY));
  // word_mask_temp = byte addresses of the words of the element.
  a_.OpIAdd(dxbc::Dest::R(word_mask_temp), address_src,
            dxbc::Src::LI((0 - int32_t(first_word_index)) * 4,
                          (1 - int32_t(first_word_index)) * 4,
                          (2 - int32_t(first_word_index)) * 4,
                          (3 - int32_t(first_word_index)) * 4));
  // word_mask_temp = whether each word is within the buffer bounds.
  a_.OpULT(dxbc::Dest::R(word_mask_temp, needed_words), dxbc::Src::R(word_mask_temp),
           dxbc::Src::R(bounds_temp, dxbc::Src::kXXXX));

  // - Load needed words to system_temp_result_, words 0, 1, 2, 3 to X, Y, Z, W
  //   respectively.
"""

ANCHOR_2 = """  a_.OpEndIf();

  dxbc::Src result_src(dxbc::Src::R(system_temp_result_));
"""

REPLACE_2 = """  a_.OpEndIf();

  // Zero the words that fall at or past the end of the fetch buffer.
  a_.OpAnd(dxbc::Dest::R(system_temp_result_, needed_words), dxbc::Src::R(system_temp_result_),
           dxbc::Src::R(word_mask_temp));
  // Release bounds_temp and word_mask_temp.
  PopSystemTemp(2);

  dxbc::Src result_src(dxbc::Src::R(system_temp_result_));
"""


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


OVERLAY = Path(__file__).resolve().parent / 'overlay'


def apply_overlay():
    """Copy the port's own changes onto the stage.

    overlay/ holds full copies of the SDK files the port modifies (plugin
    diagnostics, the foliage workaround, texture dump and replacement), each
    recorded with the SHA-256 of the pristine file it was made from. A file is
    only replaced when the pristine source is still that exact revision, so a
    different SDK stops here instead of silently mixing versions. Without this
    step those changes lived only in a local stage and vanished from every
    plugin rebuilt from a package.
    """
    manifest_path = OVERLAY / 'overlay-manifest.json'
    if not manifest_path.is_file():
        return []
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    applied = []
    for entry in manifest['files']:
        rel = entry['path']
        overlay_file = OVERLAY / rel
        staged_file = STAGE / rel
        pristine_file = SOURCE / rel
        if not overlay_file.is_file():
            raise SystemExit(f'Overlay file is missing: {overlay_file}')
        if sha256(overlay_file) != entry['overlay_sha256']:
            raise SystemExit(f'Overlay file does not match its manifest: {rel}; rerun Update-Overlay.ps1.')
        if entry['pristine_sha256'] is not None:
            if not pristine_file.is_file() or sha256(pristine_file) != entry['pristine_sha256']:
                raise SystemExit(f'Pinned SDK file changed: {rel}; review the overlay before applying.')
        staged_file.parent.mkdir(parents=True, exist_ok=True)
        if not staged_file.is_file() or sha256(staged_file) != entry['overlay_sha256']:
            shutil.copyfile(overlay_file, staged_file)
            print(f'overlay applied: {rel}')
        applied.append({'path': rel, 'sha256': entry['overlay_sha256']})
    return applied


def main():
    if not SOURCE.is_dir():
        raise SystemExit(
            'ReXGlue source is missing. Expected one of '
            f'{ROOT / "integration/rexglue-runtime-build/src"} or {ROOT / "sdk-source"}.')
    refresh = '--refresh' in sys.argv
    if refresh and STAGE.exists():
        shutil.rmtree(STAGE)
    if not STAGE.exists():
        print(f'staging {SOURCE} -> {STAGE}')
        shutil.copytree(SOURCE, STAGE, ignore=shutil.ignore_patterns('.git'))

    target = STAGE / REL
    original_sha = sha256(SOURCE / REL)
    text = target.read_text(encoding='utf-8')
    already = 'word_mask_temp' in text
    if not already:
        for anchor in (ANCHOR_1, ANCHOR_2):
            if text.count(anchor) != 1:
                raise SystemExit('Pinned translator text changed; review the anchors before patching.')
        text = text.replace(ANCHOR_1, REPLACE_1).replace(ANCHOR_2, REPLACE_2)
        target.write_text(text, encoding='utf-8', newline='\n')
        print('applied vertex-fetch bounds mask')
    else:
        print('stage already patched')

    overlay = apply_overlay()
    if REL in {item['path'] for item in overlay} and 'word_mask_temp' not in (STAGE / REL).read_text(encoding='utf-8'):
        raise SystemExit('The overlay replaced the translator without the vertex-fetch bounds fix.')

    receipt = {
        'generated_utc': datetime.now(timezone.utc).isoformat(),
        'purpose': 'Restore Xenos vertex-fetch out-of-bounds zeroing in the D3D12 shader translator',
        'symptom': 'Call of Duty 3 grass stretched into long streaks (vertices past the buffer read stale memory)',
        'source_worktree': str(SOURCE),
        'stage': str(STAGE),
        'file': REL,
        'pinned_sha256': original_sha,
        'patched_sha256': sha256(target),
        'source_kind': 'workspace-worktree' if SOURCE.name == 'src' else 'packaged-sdk-source',
        'xenia_reference': str(XENIA.relative_to(ROOT)) if XENIA.is_file() else None,
        'xenia_reference_sha256': sha256(XENIA) if XENIA.is_file() else None,
        'edits_pinned_sdk_source': False,
        'overlay_files': overlay,
    }
    out = Path(__file__).resolve().parent / 'fix-receipt.json'
    out.write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    print(json.dumps(receipt, indent=2))


main()
