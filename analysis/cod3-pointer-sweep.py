"""Read-only static pointer crosscheck against independent XenonRecomp discovery."""
import bisect
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / 'analysis/title-python'))
from capstone import Cs, CS_ARCH_PPC, CS_MODE_32, CS_MODE_BIG_ENDIAN

image = (root / 'analysis/title-default-image.bin').read_bytes()
metadata = json.loads((root / 'analysis/title-default-image.json').read_text(encoding='utf-8-sig'))
base = int(metadata['pe']['base'], 16)
rex_text = (root / 'cod3-pc/generated/default/cod3_pc_register.cpp').read_text()
xenon_text = (root / 'analysis/title-xenon-generated/ppc_func_mapping.cpp').read_text()
rex = {int(s, 16) for s in re.findall(r'SetFunction\(0x([0-9A-Fa-f]+)', rex_text)}
xenon = sorted({int(s, 16) for s in re.findall(r'\{ 0x([0-9A-Fa-f]+),', xenon_text)})
sections = metadata['pe']['sections']
code_ranges = [(int(s['address'], 16), int(s['address'], 16) + s['virtual_size']) for s in sections if s['executable']]
missing = set(xenon) - rex
refs = {}
for section in sections:
    if section['name'] not in ('.rdata', '.data'):
        continue
    begin = section['rva']
    end = begin + section['virtual_size']
    for off in range(begin, min(end, len(image)) - 3, 4):
        word = struct.unpack_from('>I', image, off)[0]
        if word in missing:
            refs.setdefault(word, []).append(base + off)

dis = Cs(CS_ARCH_PPC, CS_MODE_32 | CS_MODE_BIG_ENDIAN)
results = []
for addr in sorted(missing):
    if not any(lo <= addr < hi for lo, hi in code_ranges):
        continue
    idx = bisect.bisect_right(xenon, addr)
    next_addr = xenon[idx] if idx < len(xenon) else addr + 256
    code = image[addr - base:next_addr - base]
    instructions = list(dis.disasm(code, addr))
    prior_word = struct.unpack_from('>I', image, addr - base - 4)[0]
    starts = sorted(rex)
    pos = bisect.bisect_left(starts, addr)
    prev_rex = starts[pos - 1] if pos else None
    next_rex = starts[pos] if pos < len(starts) else None
    results.append({
        'address': f'0x{addr:08X}', 'next_xenon_start': f'0x{next_addr:08X}',
        'span': len(code), 'previous_word': f'{prior_word:08X}',
        'previous_rex_start': f'0x{prev_rex:08X}' if prev_rex else None,
        'next_rex_start': f'0x{next_rex:08X}' if next_rex else None,
        'static_data_refs': [f'0x{r:08X}' for r in refs.get(addr, [])],
        'instructions': [{'address': f'0x{i.address:08X}', 'word': bytes(i.bytes).hex().upper(), 'assembly': f'{i.mnemonic} {i.op_str}'.strip()} for i in instructions],
        'whole_span_decoded': sum(i.size for i in instructions) == len(code),
    })

report = {
    'input_xex_sha256': metadata['source_xex_sha256'],
    'image_sha256': hashlib.sha256(image).hexdigest(),
    'rex_registered_count': len(rex), 'xenon_registered_count': len(xenon),
    'missing_from_rex_count': len(results),
    'static_data_referenced_count': sum(bool(r['static_data_refs']) for r in results),
    'scope': 'Independent XenonRecomp function entries missing from ReXGlue, with static rdata/data references and machine disassembly. Candidates require manual boundary review; no project changes performed.',
    'candidates': results,
}
out = root / 'analysis/cod3-pointer-sweep.json'
out.write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps({k:v for k,v in report.items() if k != 'candidates'}, indent=2))
for result in results:
    if result['static_data_refs'] or result['address'] == '0x822C27F8':
        print(result['address'], 'span', result['span'], 'prev', result['previous_word'], 'refs', len(result['static_data_refs']), 'last', result['instructions'][-1] if result['instructions'] else None)
