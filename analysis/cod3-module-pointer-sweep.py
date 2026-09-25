"""Read-only sweep: code addresses referenced by lis/addi pairs or absolute data
pointers in each mission DLL image that ReXGlue did not register as functions.

Inputs: analysis/cod3-coroutine-module-images/<module>.bin (reconstructed image
at 0x89000000) and cod3-pc/generated/<module>/cod3_pc_register.cpp.
Output: analysis/cod3-module-pointer-sweep.json plus a console summary.
No project file is modified; candidates need manual boundary review."""
import json
import re
import struct
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / 'analysis/title-python'))
from capstone import Cs, CS_ARCH_PPC, CS_MODE_32, CS_MODE_BIG_ENDIAN

BASE = 0x89000000
MODULES = ['blkbrn', 'chambois', 'credits', 'crssrds', 'falaise', 'forest', 'fuelplnt',
           'hostage', 'island', 'laison', 'mace2', 'mayenne', 'nightd', 'saint_lo', 'stbert']
dis = Cs(CS_ARCH_PPC, CS_MODE_32 | CS_MODE_BIG_ENDIAN)


def pe_sections(image):
    e_lfanew = struct.unpack_from('<I', image, 0x3C)[0]
    assert image[e_lfanew:e_lfanew + 4] == b'PE\0\0', 'not a PE image'
    count = struct.unpack_from('<H', image, e_lfanew + 6)[0]
    opt_size = struct.unpack_from('<H', image, e_lfanew + 20)[0]
    table = e_lfanew + 24 + opt_size
    sections = []
    for i in range(count):
        off = table + 40 * i
        name = image[off:off + 8].rstrip(b'\0').decode('ascii', 'replace')
        vsize, rva = struct.unpack_from('<II', image, off + 8)
        flags = struct.unpack_from('<I', image, off + 36)[0]
        sections.append({'name': name, 'rva': rva, 'size': vsize,
                         'exec': bool(flags & 0x20000020)})
    return sections


def is_start_like(words, idx):
    prev = words[idx - 1] if idx > 0 else 0
    cur = words[idx]
    prev_terminator = (prev == 0x4E800020 or prev == 0x4E800420 or prev == 0 or
                       ((prev & 0xFC000003) == 0x48000000))  # blr, bctr, pad, b (no link)
    prologue = (cur == 0x7D8802A6 or (cur & 0xFFFF0000) == 0x94210000 or  # mflr r12 / stwu r1
                (cur & 0xFC000000) == 0x48000000 and (cur & 1) == 1)       # bl (save-regs helper)
    return prev_terminator, prologue


def decode(words, idx, limit=8):
    out = []
    for k in range(idx, min(idx + limit, len(words))):
        code = struct.pack('>I', words[k])
        ins = list(dis.disasm(code, BASE + 4 * k))
        out.append('%08X %08X %s' % (BASE + 4 * k, words[k],
                                     (ins[0].mnemonic + ' ' + ins[0].op_str).strip() if ins else '??'))
        if words[k] == 0x4E800020 or words[k] == 0x4E800420:
            break
    return out


report = {'base': '0x89000000', 'modules': {}}
total = 0
for module in MODULES:
    image = (root / 'analysis/cod3-coroutine-module-images' / (module + '.bin')).read_bytes()
    sections = pe_sections(image)
    code_ranges = [(BASE + s['rva'], BASE + s['rva'] + s['size']) for s in sections if s['exec']]
    data_ranges = [(BASE + s['rva'], BASE + s['rva'] + s['size']) for s in sections if not s['exec']]
    reg_text = (root / 'cod3-pc/generated' / module / 'cod3_pc_register.cpp').read_text()
    registered = sorted({int(s, 16) for s in re.findall(r'SetFunction\(0x([0-9A-Fa-f]+)', reg_text)})
    regset = set(registered)
    n = len(image) >> 2
    words = struct.unpack('>%dI' % n, image[:n * 4])

    def in_code(a):
        return any(lo <= a < hi for lo, hi in code_ranges)

    refs = {}
    # (a) lis rD,hi ; addi/ori rX,rD,lo  within 8 instructions
    for i in range(n):
        w = words[i]
        if (w & 0xFC1F0000) != 0x3C000000:
            continue
        if not in_code(BASE + 4 * i):
            continue
        rd = (w >> 21) & 31
        hi = w & 0xFFFF
        for j in range(i + 1, min(i + 9, n)):
            w2 = words[j]
            if (w2 & 0xFC000000) == 0x38000000 and ((w2 >> 16) & 31) == rd:
                lo = w2 & 0xFFFF
                if lo & 0x8000:
                    lo -= 0x10000
                addr = ((hi << 16) + lo) & 0xFFFFFFFF
                if in_code(addr):
                    refs.setdefault(addr, []).append({'kind': 'lis/addi', 'at': '0x%08X' % (BASE + 4 * i)})
                break
            if (w2 & 0xFC000000) == 0x60000000 and ((w2 >> 21) & 31) == rd:
                addr = ((hi << 16) | (w2 & 0xFFFF)) & 0xFFFFFFFF
                if in_code(addr):
                    refs.setdefault(addr, []).append({'kind': 'lis/ori', 'at': '0x%08X' % (BASE + 4 * i)})
                break
            # the lis register was overwritten by something else
            if ((w2 >> 21) & 31) == rd and (w2 & 0xFC000000) not in (0x38000000, 0x60000000):
                break
    # (b) absolute pointers in non-executable sections
    for lo_r, hi_r in data_ranges:
        start = (lo_r - BASE) >> 2
        end = min((hi_r - BASE) >> 2, n)
        for i in range(start, end):
            w = words[i]
            if (w & 3) == 0 and in_code(w):
                refs.setdefault(w, []).append({'kind': 'data-ptr', 'at': '0x%08X' % (BASE + 4 * i)})

    candidates = []
    for addr in sorted(refs):
        if addr in regset:
            continue
        idx = (addr - BASE) >> 2
        prev_term, prologue = is_start_like(words, idx)
        # nearest registered neighbours
        import bisect
        pos = bisect.bisect_left(registered, addr)
        prev_reg = registered[pos - 1] if pos else None
        next_reg = registered[pos] if pos < len(registered) else None
        candidates.append({
            'address': '0x%08X' % addr,
            'refs': refs[addr][:6], 'ref_count': len(refs[addr]),
            'prev_word_terminator': prev_term, 'has_prologue': prologue,
            'previous_registered': '0x%08X' % prev_reg if prev_reg else None,
            'next_registered': '0x%08X' % next_reg if next_reg else None,
            'gap_to_next_registered': (next_reg - addr) if next_reg else None,
            'disassembly': decode(words, idx),
        })
    report['modules'][module] = {
        'registered_count': len(registered), 'candidate_count': len(candidates),
        'sections': sections, 'candidates': candidates,
    }
    total += len(candidates)
    likely = [c for c in candidates if c['prev_word_terminator']]
    print('%-9s registered=%5d candidates=%3d start-like=%3d' % (module, len(registered), len(candidates), len(likely)))
    for c in likely:
        print('   %s refs=%d kinds=%s gap=%s first=%s' % (
            c['address'], c['ref_count'], sorted({r['kind'] for r in c['refs']}),
            c['gap_to_next_registered'], c['disassembly'][0] if c['disassembly'] else '?'))

(root / 'analysis/cod3-module-pointer-sweep.json').write_text(json.dumps(report, indent=1), encoding='utf-8')
print('total candidates', total)
