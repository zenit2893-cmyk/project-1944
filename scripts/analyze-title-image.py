#!/usr/bin/env python3
"""Reconstruct a local basic-compressed XEX image and record static evidence.

Uses the public loader key constants from a local ReXGlue source checkout and
the installed cryptography package. No input is modified. The output image is
private game-derived analysis data and must not be distributed with a port.
Only XEX2 none/basic compression is supported; normal/LZX fails explicitly.
"""
import argparse
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct
import sys


def reconstruct(xex, sdk_source):
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    data = xex.read_bytes()
    if data[:4] != b"XEX2":
        raise ValueError("Not an XEX2 file")
    u32 = lambda off: struct.unpack_from(">I", data, off)[0]
    header_size, security, count = u32(8), u32(16), u32(20)
    headers = dict(struct.unpack_from(">2I", data, 24 + i * 8) for i in range(count))
    info = headers[0x3FF]
    info_size, enc, comp = struct.unpack_from(">IHH", data, info)
    if comp not in (0, 1) or enc not in (0, 1):
        raise ValueError(f"Unsupported encryption/compression {enc}/{comp}")
    if comp == 1:
        if info_size < 8 or (info_size - 8) % 8:
            raise ValueError("Invalid basic-compression descriptor size")
        blocks = [struct.unpack_from(">2I", data, off)
                  for off in range(info + 8, info + info_size, 8)]
    else:
        blocks = [(len(data) - header_size, 0)]
    payload = data[header_size:]
    wanted = sum(length for length, _ in blocks)
    if wanted > len(payload):
        raise ValueError("Compressed image exceeds file")
    payload = payload[:wanted]
    key_source = sdk_source / "src/system/xex_module.cpp"
    loader = key_source.read_text(encoding="utf-8")
    variants = ["retail", "devkit"] if enc else ["none"]
    image = None
    selected = None
    for variant in variants:
        if enc:
            match = re.search(r"xe_xex2_" + variant + r"_key\[16\]\s*=\s*\{([^}]+)\}", loader)
            if not match:
                raise ValueError("Public loader key definition not found in SDK source")
            public_loader_key = bytes(int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]+)", match.group(1)))
            def decrypt(ciphertext, key):
                worker = Cipher(algorithms.AES(key), modes.CBC(bytes(16))).decryptor()
                return worker.update(ciphertext) + worker.finalize()
            session_key = decrypt(data[security + 0x150:security + 0x160], public_loader_key)
            plain = decrypt(payload, session_key)
        else:
            plain = payload
        parts, cursor = [], 0
        for length, zero_length in blocks:
            parts.extend((plain[cursor:cursor + length], bytes(zero_length)))
            cursor += length
        candidate = b"".join(parts)
        if candidate[:2] == b"MZ":
            pe_offset = struct.unpack_from("<I", candidate, 0x3C)[0]
            if candidate[pe_offset:pe_offset + 4] == b"PE\0\0":
                image, selected = candidate, variant
                break
    if image is None:
        raise ValueError("Reconstruction failed MZ/PE signature checks")
    declared_size = u32(security + 4)
    if len(image) > declared_size:
        raise ValueError("Reconstructed image exceeds XEX security image size")
    image = image.ljust(declared_size, b"\0")
    return image, {"compression": comp, "encryption": enc, "loader_variant": selected,
                   "basic_blocks": [{"data_size": a, "zero_size": z} for a, z in blocks],
                   "public_loader_source": str(key_source.resolve()),
                   "public_loader_source_sha256": hashlib.sha256(key_source.read_bytes()).hexdigest().upper()}


def inspect_pe(image):
    pe = struct.unpack_from("<I", image, 0x3C)[0]
    machine, count, stamp, _, _, optional_size, flags = struct.unpack_from("<HHIIIHH", image, pe + 4)
    optional = pe + 24
    magic = struct.unpack_from("<H", image, optional)[0]
    if magic != 0x10B:
        raise ValueError("Only PE32 image layout supported")
    base = struct.unpack_from("<I", image, optional + 28)[0]
    sections = []
    for i in range(count):
        off = optional + optional_size + i * 40
        name, virtual_size, rva, raw_size, raw_pointer, _, _, _, _, characteristics = struct.unpack_from("<8sIIIIIIHHI", image, off)
        sections.append({"name": name.rstrip(b"\0").decode("ascii", "replace"),
                         "address": f"0x{base+rva:08X}", "rva": rva,
                         "virtual_size": virtual_size, "raw_size": raw_size,
                         "raw_pointer": raw_pointer, "flags": f"0x{characteristics:08X}",
                         "executable": bool(characteristics & 0x20000000)})
    return {"machine": f"0x{machine:04X}", "base": f"0x{base:08X}",
            "entry_point": f"0x{base+struct.unpack_from('<I', image, optional+16)[0]:08X}",
            "timestamp_unix": stamp,
            "timestamp_utc": dt.datetime.fromtimestamp(stamp, dt.timezone.utc).isoformat(),
            "sections": sections}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xex", type=Path)
    parser.add_argument("--sdk-source", type=Path, default=Path("tools/rexglue-source"))
    parser.add_argument("--out-prefix", type=Path, required=True)
    parser.add_argument("--python-packages", type=Path, default=Path("analysis/title-python"))
    args = parser.parse_args()
    sys.path.insert(0, str(args.python_packages.resolve()))
    import xxhash
    image, reconstruction = reconstruct(args.xex, args.sdk_source)
    pe = inspect_pe(image)
    base = int(pe["base"], 16)
    prefix = args.out_prefix
    prefix.parent.mkdir(parents=True, exist_ok=True)
    image_path = prefix.with_suffix(".bin")
    image_path.write_bytes(image)
    data = args.xex.read_bytes()
    security = struct.unpack_from(">I", data, 16)[0]
    count = struct.unpack_from(">I", data, security + 0x180)[0]
    flags = struct.unpack_from(">I", data, security + 0x10C)[0]
    page_size = 4096 if flags & 0x10000000 else 65536
    descriptors = [struct.unpack_from(">I", data, security+0x184+i*24)[0] for i in range(count)]
    code_indices = [i for i, value in enumerate(descriptors) if value & 15 == 1]
    if not code_indices:
        raise ValueError("No XEX code page descriptors")
    # Reproduces Xenia Canary UserModule::CalculateHash exactly (descriptor indices).
    begin, end = min(code_indices) * page_size, (max(code_indices)+1)*page_size
    module_hash = xxhash.xxh3_64(image[begin:end]).hexdigest().upper()
    pattern = re.compile(r"(?i)(\bcom_maxfps\b|\bfixedtime\b|\btimescale\b|framerate|frametime|frame_time|\bpmove|\bsv_fps\b|\bcg_fov\b|nglPresent|nglListSend|NGL 3|physics|DemonWare|havok)")
    strings = [{"address": f"0x{base+m.start():08X}", "text": m.group().decode("ascii")}
               for m in re.finditer(rb"[ -~]{5,}", image)
               if pattern.search(m.group().decode("ascii"))]
    result = {"schema_version": 1, "analyzed_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
              "source_xex": str(args.xex.resolve()), "source_xex_sha256": hashlib.sha256(data).hexdigest().upper(),
              "image": str(image_path.resolve()), "image_size": len(image),
              "image_sha256": hashlib.sha256(image).hexdigest().upper(),
              "image_scope": "Reconstructed original image before runtime import patches; local private analysis data.",
              "reconstruction": reconstruction, "pe": pe,
              "xenia_canary_module_hash": {"algorithm": "XXH3_64", "value": module_hash,
                  "start_address": f"0x{base+begin:08X}", "end_address_exclusive": f"0x{base+end:08X}",
                  "source": "https://github.com/xenia-canary/xenia-canary/blob/canary_experimental/src/xenia/kernel/user_module.cc#L1070-L1107",
                  "matches_public_cod3_sp_tu0_patch": module_hash == "B796871E700C5C6B"},
              "string_anchors": strings,
              "evidence_scope": "Static metadata and literal strings; function semantics and live timing behavior are not established."}
    prefix.with_suffix(".json").write_text(json.dumps(result, indent=2, ensure_ascii=False)+"\n", encoding="utf-8")
    print(json.dumps({"image_sha256": result["image_sha256"], "pe": {k:v for k,v in pe.items() if k!='sections'},
                      "xenia_canary_module_hash": result["xenia_canary_module_hash"], "string_anchors": strings}, indent=2))


if __name__ == "__main__":
    main()
