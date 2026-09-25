#!/usr/bin/env python3
"""Read local XEX2 headers without decrypting or modifying the source file.

Layout reference: win-amd64/include/rex/system/util/xex2_info.h from the
installed ReXGlue SDK, adapted from Xenia. Only standard-library modules used.
Encrypted image contents, keys and signatures are deliberately not exported.
"""

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import struct


KEYS = {
    0x000002FF: "resource_info", 0x000003FF: "file_format_info",
    0x000005FF: "delta_patch_descriptor", 0x000080FF: "bounding_path",
    0x00010001: "original_base_address", 0x00010100: "entry_point",
    0x00010201: "image_base_address", 0x000103FF: "import_libraries",
    0x00018002: "checksum_timestamp", 0x000183FF: "original_pe_name",
    0x000200FF: "static_libraries", 0x00020104: "tls_info",
    0x00020200: "default_stack_size", 0x00020301: "default_filesystem_cache_size",
    0x00020401: "default_heap_size", 0x00030000: "system_flags",
    0x00040006: "execution_info", 0x00040201: "title_workspace_size",
    0x00040310: "game_ratings", 0x00040404: "lan_key",
    0x000405FF: "xbox360_logo", 0x000406FF: "multidisc_media_ids",
    0x000407FF: "alternate_title_ids", 0x00040801: "additional_title_memory",
    0x00E10402: "exports_by_name",
}


def hex32(value):
    return f"0x{value:08X}"


def version(value):
    return {"raw": hex32(value), "formatted":
            f"{value >> 28}.{(value >> 24) & 15}.{(value >> 8) & 0xFFFF}.{value & 255}"}


def analyze(path):
    data = path.read_bytes()

    def read(fmt, off):
        length = struct.calcsize(fmt)
        if off < 0 or off + length > len(data):
            raise ValueError(f"Out-of-bounds structure at {off:#x}, size {length:#x}")
        return struct.unpack_from(fmt, data, off)

    def u32(off):
        return read(">I", off)[0]

    def string(off, length):
        if off < 0 or off + length > len(data):
            raise ValueError("Out-of-bounds string")
        return data[off:off + length].split(b"\0", 1)[0].decode("ascii", "replace")

    if data[:4] != b"XEX2":
        raise ValueError("Source is not an XEX2 file")
    flags, header_size, reserved, security_offset, header_count = read(">5I", 4)
    if header_size > len(data) or 24 + header_count * 8 > header_size:
        raise ValueError("Invalid XEX2 header bounds")
    headers = dict(read(">2I", 24 + i * 8) for i in range(header_count))
    result = {
        "schema_version": 1,
        "analyzed_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "source": {"path": str(path.resolve()), "size_bytes": len(data),
                   "sha256": hashlib.sha256(data).hexdigest().upper(),
                   "sha1": hashlib.sha1(data).hexdigest().upper(),
                   "md5": hashlib.md5(data).hexdigest().upper()},
        "xex": {"magic": "XEX2", "module_flags": hex32(flags),
                "header_size": header_size, "security_offset": security_offset,
                "optional_header_count": header_count,
                "headers": [{"key": hex32(k), "name": KEYS.get(k, "unknown"),
                             "value_or_offset": hex32(v)} for k, v in headers.items()
                            if k != 0x00040404]},
        "evidence_scope": "Cleartext XEX2 container headers; no image decryption, execution or function semantics verified.",
    }
    if 0x00010100 in headers:
        result["entry_point"] = hex32(headers[0x00010100])
    if 0x00010201 in headers:
        result["image_base"] = hex32(headers[0x00010201])
    s = security_offset
    result["security_metadata"] = {
        "image_size": u32(s + 4), "image_flags": hex32(u32(s + 0x10C)),
        "load_address": hex32(u32(s + 0x110)),
        "import_table_count": u32(s + 0x128),
        "export_table": hex32(u32(s + 0x160)), "region_flags": hex32(u32(s + 0x178)),
        "allowed_media_types": hex32(u32(s + 0x17C)),
        "page_descriptor_count": u32(s + 0x180),
    }
    if 0x00040006 in headers:
        p = headers[0x00040006]
        media, ver, base, title, platform, executable_table, disc, count, save = read(">4I4BI", p)
        result["execution_info"] = {
            "title_id": f"{title:08X}", "media_id": f"{media:08X}",
            "version": version(ver), "base_version": version(base),
            "platform": platform, "executable_table": executable_table,
            "disc_number": disc, "disc_count": count, "savegame_id": f"{save:08X}",
        }
    if 0x000003FF in headers:
        p = headers[0x000003FF]
        size, enc, comp = read(">IHH", p)
        result["file_format"] = {
            "info_size": size, "encryption_type": enc,
            "encryption": {0: "none", 1: "normal"}.get(enc, "unknown"),
            "compression_type": comp,
            "compression": {0: "none", 1: "basic", 2: "normal", 3: "delta"}.get(comp, "unknown"),
        }
    if 0x000183FF in headers:
        p = headers[0x000183FF]
        result["original_pe_name"] = string(p + 4, u32(p) - 4)
    if 0x000080FF in headers:
        p = headers[0x000080FF]
        result["bounding_path"] = string(p + 4, u32(p) - 4)
    if 0x00018002 in headers:
        p = headers[0x00018002]
        checksum, timestamp = read(">2I", p)
        result["checksum_timestamp"] = {
            "checksum": hex32(checksum), "timestamp_unix": timestamp,
            "timestamp_utc": dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).isoformat()}
    if 0x000002FF in headers:
        p = headers[0x000002FF]
        result["resources"] = [{"name": string(o, 8), "address": hex32(u32(o + 8)),
                                "size": u32(o + 12)} for o in range(p + 4, p + u32(p), 16)]
    if 0x000200FF in headers:
        p = headers[0x000200FF]
        result["static_libraries"] = []
        for o in range(p + 4, p + u32(p), 16):
            major, minor, build, approval, qfe = read(">HHHBB", o + 8)
            result["static_libraries"].append({"name": string(o, 8),
                                              "version": f"{major}.{minor}.{build}.{qfe}",
                                              "approval_type": approval})
    if 0x00020104 in headers:
        values = read(">4I", headers[0x00020104])
        result["tls"] = dict(zip(["slot_count", "raw_data_address", "data_size", "raw_data_size"], values))
        result["tls"]["raw_data_address"] = hex32(values[1])
    if 0x000103FF in headers:
        p = headers[0x000103FF]
        size, string_size, string_count = read(">3I", p)
        names = []
        cursor = p + 12
        while cursor < p + 12 + string_size and len(names) < string_count:
            name = string(cursor, p + 12 + string_size - cursor)
            if name:
                names.append(name)
            cursor += len(name.encode("ascii", "replace")) + 1
            cursor = (cursor + 3) & ~3
        result["imports"] = {"names": names, "libraries": []}
        cursor = p + 12 + string_size
        while cursor < p + size:
            length = u32(cursor)
            if length == 0:
                break
            library_id, ver, minimum, name_index, count = read(">IIIHH", cursor + 24)
            if length < 40 + count * 4 or cursor + length > p + size:
                raise ValueError("Invalid import library bounds")
            result["imports"]["libraries"].append({
                "name": names[name_index & 255] if (name_index & 255) < len(names) else None,
                "name_index": name_index, "id": hex32(library_id),
                "version": version(ver), "minimum_version": version(minimum),
                "entry_count": count,
                "entry_addresses": [hex32(u32(cursor + 40 + i * 4)) for i in range(count)],
                "resolution": "Addresses are import records in loaded image; ordinals require image contents.",
            })
            cursor += length
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xex", type=Path, help="One XEX2 file or a directory of .xex/.dll files")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.xex.is_dir():
        paths = sorted(p for p in args.xex.rglob("*")
                       if p.is_file() and p.suffix.lower() in (".xex", ".dll"))
        metadata = {"schema_version": 1, "modules": [analyze(p) for p in paths]}
    else:
        metadata = analyze(args.xex)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    summaries = [{k: module[k] for k in ["source", "execution_info", "entry_point", "image_base", "file_format"] if k in module}
                 for module in metadata.get("modules", [metadata])]
    print(json.dumps(summaries, indent=2, ensure_ascii=True))


if __name__ == "__main__":
    main()
