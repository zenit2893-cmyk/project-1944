#!/usr/bin/env python3
"""Verify complete Xbox 360 save/restore helpers for XenonRecomp configuration.

Checks the entire fallthrough sequence and terminator, not only a prefix.
Uses the PPC/VMX128 instruction layouts documented in the checked-out
XenonRecomp README and thirdparty/disasm/ppc-dis.c. It never edits game data.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def pack(words):
    return b"".join(struct.pack(">I", word) for word in words)


def helper_sequences():
    seq = {}
    for load in (True, False):
        prefix = "rest" if load else "save"
        gpr = [(0xE8000000 if load else 0xF8000000) | (r << 21) | (1 << 16) | ((-0x98 + (r-14)*8) & 0xFFFF)
               for r in range(14, 32)]
        gpr += [0x8181FFF8, 0x7D8803A6, 0x4E800020] if load else [0x9181FFF8, 0x4E800020]
        seq[prefix+"gprlr_14_address"] = pack(gpr)
        fpr = [(0xC8000000 if load else 0xD8000000) | (r << 21) | (12 << 16) | ((-0x90+(r-14)*8)&0xFFFF)
               for r in range(14, 32)] + [0x4E800020]
        seq[prefix+"fpr_14_address"] = pack(fpr)
        vmx = []
        for r in range(14, 32):
            vmx.extend([0x39600000 | ((-0x120+(r-14)*16)&0xFFFF),
                        (0x7C0B60CE if load else 0x7C0B61CE) | (r << 21)])
        seq[prefix+"vmx_14_address"] = pack(vmx+[0x4E800020])
        vmx128 = []
        for r in range(64, 128):
            vmx128.extend([0x39600000 | ((-0x400+(r-64)*16)&0xFFFF),
                           (0x100B60C3 if load else 0x100B61C3) | ((r&31)<<21) | ((r&0x60)>>3)])
        seq[prefix+"vmx_64_address"] = pack(vmx128+[0x4E800020])
    return seq


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, default=Path("analysis/title-default-image.bin"))
    parser.add_argument("--metadata", type=Path, default=Path("analysis/title-default-image.json"))
    parser.add_argument("--out-prefix", type=Path, default=Path("analysis/title-xenon-helpers"))
    args = parser.parse_args()
    image = args.image.read_bytes()
    metadata = json.loads(args.metadata.read_text(encoding="utf-8"))
    if hashlib.sha256(image).hexdigest().upper() != metadata["image_sha256"]:
        raise ValueError("Image hash no longer matches reconstruction receipt")
    base = int(metadata["pe"]["base"], 16)
    sections = [s for s in metadata["pe"]["sections"] if s["executable"]]
    findings = []
    for name, sequence in helper_sequences().items():
        matches = []
        for section in sections:
            begin, end = section["rva"], section["rva"]+section["virtual_size"]
            cursor = begin
            while (off := image.find(sequence, cursor, end)) >= 0:
                if off % 4 == 0:
                    matches.append(base+off)
                cursor = off+1
        if len(matches) != 1:
            raise ValueError(f"Expected one complete {name} helper, found {len(matches)}")
        address = matches[0]
        callers = []
        for section in sections:
            for off in range(section["rva"], section["rva"]+section["virtual_size"]-3, 4):
                word = struct.unpack_from(">I", image, off)[0]
                if word >> 26 != 18:
                    continue
                displacement = word & 0x03FFFFFC
                if displacement & 0x02000000:
                    displacement -= 0x04000000
                target = displacement if word & 2 else base+off+displacement
                stride = 8 if "vmx" in name else 4
                reg_count = 64 if "_64_" in name else 18
                if address <= target < address+reg_count*stride and (target-address)%stride == 0:
                    callers.append({"address": f"0x{base+off:08X}", "target": f"0x{target:08X}", "link": bool(word&1)})
        findings.append({"config_key": name, "address": f"0x{address:08X}",
                         "full_sequence_size": len(sequence), "full_sequence_sha256": hashlib.sha256(sequence).hexdigest().upper(),
                         "exact_full_sequence_matches": len(matches), "full_sequence_hex": sequence.hex().upper(),
                         "direct_branch_reference_count": len(callers), "sample_references": callers[:8],
                         "validated": True})
    output = {"schema_version": 1, "source_xex_sha256": metadata["source_xex_sha256"],
              "image_sha256": metadata["image_sha256"], "helpers": findings,
              "method": "Every expected register save/restore instruction, displacement, register progression and final return matched byte-for-byte in an executable section.",
              "sources": ["tools/XenonRecomp/README.md:158-169", "tools/XenonRecomp/thirdparty/disasm/ppc-dis.c:1607-1624", "tools/XenonRecomp/XenonRecomp/recompiler.cpp:95-168"],
              "not_established": ["setjmp/longjmp helper identity", "execution correctness", "FPS behavior"]}
    args.out_prefix.parent.mkdir(parents=True, exist_ok=True)
    args.out_prefix.with_suffix(".json").write_text(json.dumps(output, indent=2)+"\n", encoding="utf-8")
    toml = ["# Verified against default.xex SHA256 "+metadata["source_xex_sha256"], "# Complete helper sequences validated; no game patches applied.", "[main]"]
    toml += [f"{item['config_key']} = {item['address']}" for item in findings]
    args.out_prefix.with_suffix(".toml").write_text("\n".join(toml)+"\n", encoding="utf-8")
    print(json.dumps([{k:v for k,v in item.items() if k not in ("full_sequence_hex", "sample_references")} for item in findings], indent=2))


if __name__ == "__main__":
    main()
