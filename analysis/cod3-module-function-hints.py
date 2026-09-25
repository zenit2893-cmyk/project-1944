"""Turn the module pointer sweep into [modules.functions] hints in the manifest.

Selection (conservative):
  * data-ptr targets (vtable / callback tables) whose first word is code, and
  * lis/addi or lis/ori targets whose preceding word is blr, bctr or zero padding,
  * never a word whose top byte is 0x89 (those are pointer tables inside .text).
Size = distance to the next ReXGlue-registered function start (bounded region).
The generated block replaces any previous [modules.functions] block per module."""
import json
import re
import struct
from pathlib import Path

root = Path(__file__).resolve().parent.parent
sweep = json.loads((root / 'analysis/cod3-module-pointer-sweep.json').read_text(encoding='utf-8'))
manifest_path = root / 'cod3-pc/cod3_pc_manifest.toml'
text = manifest_path.read_text(encoding='utf-8')
BASE = 0x89000000

hints = {}
for module, data in sweep['modules'].items():
    image = (root / 'analysis/cod3-coroutine-module-images' / (module + '.bin')).read_bytes()
    sections = data['sections']

    def section_of(addr):
        for s in sections:
            if BASE + s['rva'] <= addr < BASE + s['rva'] + s['size']:
                return s['name']
        return None

    selected = []
    for c in data['candidates']:
        addr = int(c['address'], 16)
        off = addr - BASE
        first = struct.unpack_from('>I', image, off)[0]
        prev = struct.unpack_from('>I', image, off - 4)[0]
        if (first >> 24) == 0x89 or first == 0:
            continue  # pointer table / padding, not code
        # blr, bctr, zero padding or an unconditional b (no link) ends the previous function
        terminator = prev in (0x4E800020, 0x4E800420, 0) or (prev & 0xFC000003) == 0x48000000
        if not terminator:
            continue  # likely an EH landing pad or block inside a registered function
        kinds = set()
        for r in c['refs']:
            if r['kind'] == 'data-ptr':
                if section_of(int(r['at'], 16)) in ('.rdata', '.data'):
                    kinds.add('data-ptr')  # vtables / callback tables only, not .pdata/.xdata
            else:
                kinds.add(r['kind'])
        if kinds:
            gap = c['gap_to_next_registered']
            if not gap or gap <= 0 or gap > 16384:
                continue
            selected.append((addr, gap, sorted(kinds), c['disassembly'][0]))
    # Two adjacent hints must not overlap: clamp each size to the next hint start.
    selected.sort()
    clamped = []
    for i, (addr, gap, kinds, first) in enumerate(selected):
        if i + 1 < len(selected):
            gap = min(gap, selected[i + 1][0] - addr)
        clamped.append((addr, gap, kinds, first))
    hints[module] = clamped

# Rewrite module blocks: strip old [modules.functions] blocks, append new ones.
parts = re.split(r'(?m)^\[\[modules\]\]\s*$', text)
head, blocks = parts[0], parts[1:]
out = [head.rstrip('\n') + '\n']
total = 0
for block in blocks:
    block = re.sub(r'(?ms)^\[modules\.functions\].*?(?=^\[\[modules\]\]|\Z)', '', block).rstrip('\n')
    m = re.search(r'(?m)^out_directory_path\s*=\s*"generated/([A-Za-z0-9_]+)"', block)
    module = m.group(1)
    entries = hints.get(module, [])
    lines = ['\n[[modules]]' + block + '\n']
    if entries:
        lines.append('\n# Function entries referenced only by lis/addi or data pointers; missed by')
        lines.append('# the SDK analyzer. Evidence: analysis/cod3-module-pointer-sweep.json.')
        lines.append('[modules.functions]')
        for addr, gap, kinds, first in entries:
            lines.append('0x%08X = { size = %d }  # %s; %s' % (addr, gap, '/'.join(kinds), first.split(' ', 2)[2]))
        lines.append('')
    total += len(entries)
    out.append('\n'.join(lines))
manifest_path.write_text(''.join(out), encoding='utf-8')
for module, entries in hints.items():
    print('%-9s %2d hints' % (module, len(entries)))
print('total', total)
