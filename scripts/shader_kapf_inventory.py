#!/usr/bin/env python3
"""Inspect COD3 KAPF directories and optionally decode one bounded NCH block.

KAPF metadata layout was checked against local COD3 assets and GameExtractor's
Plugin_COD_KAPF.java. NCH offsets/lengths/chunk boundaries are observations from
this disc revision. File locators inside APKF are deliberately left uninterpreted.
No original file is changed, and this script is not a generic KAPF extractor.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import mmap
import struct
import sys
from datetime import datetime, timezone
from pathlib import Path, PureWindowsPath

MIB = 1024 * 1024
NCH_ALIGNMENT = 0x80000
REFERENCE = "https://github.com/wattostudios/GameExtractor/blob/master/src/org/watto/ge/plugin/archive/Plugin_COD_KAPF.java"


def require_span(offset: int, length: int, boundary: int, label: str) -> None:
    if offset < 0 or length < 0 or offset + length > boundary:
        raise ValueError(f"{label} outside file/section: {offset:#x} + {length:#x} > {boundary:#x}")


def read_name(data: mmap.mmap, offset: int, boundary: int) -> str:
    require_span(offset, 1, boundary, "name")
    end = data.find(b"\0", offset, min(boundary, offset + 4096))
    if end < 0:
        raise ValueError(f"unterminated or oversized name at {offset:#x}")
    return data[offset:end].decode("latin1")


def inspect(path: Path, max_metadata_bytes: int) -> dict:
    size = path.stat().st_size
    with path.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        require_span(0, 48, size, "KAPF header")
        magic, version, directory_offset, count, details_offset, names_offset, names_end = struct.unpack_from("<4sf5I", data)
        if magic != b"KAPF" or abs(version - 2.06) > 0.001:
            raise ValueError(f"unsupported KAPF magic/version: {magic!r} / {version}")
        require_span(directory_offset, count * 24, size, "directory array")
        require_span(names_offset, names_end - names_offset, size, "source name table")
        if names_end > max_metadata_bytes:
            raise ValueError("metadata exceeds configured cap")
        result = {"path": str(path.resolve()), "size": size, "version": version, "description": data[28:48].rstrip(b"\0").decode("latin1"), "metadata_end": names_end, "directories": []}
        all_extensions = collections.Counter()
        for index in range(count):
            raw_name, block_count, entry_count, blocks_offset, entry_offset = struct.unpack_from("<12s2H2I", data, directory_offset + index * 24)
            require_span(blocks_offset, block_count * 32, names_end, "block metadata")
            require_span(entry_offset, entry_count * 20, names_end, "file metadata")
            directory = {"index": index, "name": raw_name.rstrip(b"\0").decode("latin1"), "entry_count": entry_count, "blocks": [], "shader_entries": []}
            for block_index in range(block_count):
                offset, length, padded, flags, packed, zero1, zero2, zero3 = struct.unpack_from("<8I", data, blocks_offset + block_index * 32)
                stored = packed if packed else length
                require_span(offset, stored, size, "block data")
                directory["blocks"].append({"index": block_index, "offset": offset, "uncompressed_length": length, "padded_length_word": padded, "flags": flags, "stored_length": stored, "compressed": packed != 0, "head_hex": data[offset:offset + 32].hex(), "magic": data[offset:offset + 4].decode("latin1")})
            for entry_index in range(entry_count):
                short_offset, source_offset, length, block, locator = struct.unpack_from("<5I", data, entry_offset + entry_index * 20)
                if source_offset < names_offset or source_offset >= names_end:
                    raise ValueError("file source name outside source-name table")
                if block >= block_count:
                    raise ValueError("file references nonexistent block")
                name = read_name(data, source_offset, names_end)
                extension = PureWindowsPath(name).suffix.lower()
                all_extensions[extension] += 1
                if extension in (".xefx", ".xvu", ".xpu", ".vsh", ".psh") or "\\shaders\\" in name.lower():
                    directory["shader_entries"].append({"entry_index": entry_index, "source_name": name, "short_name": read_name(data, short_offset, names_end), "declared_length": length, "block_index": block, "locator_word": f"0x{locator:08X}", "locator_interpretation": "unverified; not a byte offset"})
            result["directories"].append(directory)
        result["extension_counts"] = dict(all_extensions)
        result["shader_entry_count"] = sum(len(d["shader_entries"]) for d in result["directories"])
        return result


def decode_block(path: Path, block: dict, output: Path, deps: Path, limit: int) -> dict:
    if output.resolve() == path.resolve():
        raise ValueError("output may not overwrite input")
    expected = block["uncompressed_length"]
    if expected > limit:
        raise ValueError("decoded block exceeds cap")
    if block["magic"] != "NCH\u0000" or not block["compressed"]:
        raise ValueError("selected block is not compressed NCH")
    sys.path.insert(0, str(deps.resolve()))
    from dissect.util.compression import lzo
    from importlib.metadata import version
    report = {"method": "NCH headers + raw LZO1X; validates boundaries, contiguous output offsets, chunk sizes, and final size", "decoder": f"dissect.util {version('dissect.util')}", "checksum_words_verified": False, "chunks": []}
    output_data = bytearray()
    base = block["offset"]
    end = base + block["stored_length"]
    offset = base
    with path.open("rb") as stream:
        while len(output_data) < expected:
            require_span(offset, 32, end, "NCH header")
            stream.seek(offset)
            header = stream.read(32)
            magic, packed, checksum1, unpacked, output_offset, checksum2, full_size, codec = struct.unpack(">8I", header)
            if magic != 0x4E434800 or codec != 1 or full_size != packed + 32:
                raise ValueError(f"unsupported NCH header at {offset:#x}")
            if output_offset != len(output_data) or unpacked <= 0:
                raise ValueError("NCH output offsets are not contiguous")
            if output_offset + unpacked > expected or unpacked > limit:
                raise ValueError("NCH output exceeds declared block size or cap")
            if full_size > NCH_ALIGNMENT:
                raise ValueError("NCH chunk exceeds observed alignment")
            require_span(offset + 32, packed, end, "NCH payload")
            payload = stream.read(packed)
            decoded = lzo.decompress(payload, header=False, buflen=unpacked)
            if len(decoded) != unpacked:
                raise ValueError("LZO output does not match NCH size")
            output_data.extend(decoded)
            report["chunks"].append({"source_offset": offset, "packed_bytes": packed, "decoded_bytes": unpacked, "decoded_offset": output_offset, "checksum_words": [f"0x{checksum1:08X}", f"0x{checksum2:08X}"], "packed_sha256": hashlib.sha256(payload).hexdigest(), "decoded_sha256": hashlib.sha256(decoded).hexdigest()})
            offset = base + ((offset - base + full_size + NCH_ALIGNMENT - 1) // NCH_ALIGNMENT) * NCH_ALIGNMENT
    if len(output_data) != expected or not output_data.startswith(b"APKF"):
        raise ValueError("decoded block does not match expected size/APKF magic")
    digest = hashlib.sha256(output_data).hexdigest()
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        if hashlib.sha256(output.read_bytes()).hexdigest() != digest:
            raise ValueError("existing output differs; refusing overwrite")
    else:
        with output.open("xb") as stream:
            stream.write(output_data)
    report.update(output=str(output.resolve()), decoded_bytes=len(output_data), sha256=digest, chunk_count=len(report["chunks"]))
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-metadata-mib", type=int, default=8)
    parser.add_argument("--decode-block", help="directory:block indexes, e.g. 0:1; optional")
    parser.add_argument("--decoded-output", type=Path)
    parser.add_argument("--max-decoded-mib", type=int, default=64)
    parser.add_argument("--python-deps", type=Path, default=Path(__file__).resolve().parent.parent / "analysis" / "graphics-python-deps")
    args = parser.parse_args()
    if args.output.resolve() == args.input.resolve() or (args.decoded_output and args.output.resolve() == args.decoded_output.resolve()):
        parser.error("report path must differ from input and decoded output")
    if args.max_metadata_mib < 1 or args.max_decoded_mib < 1:
        parser.error("caps must be positive")
    report = {"schema_version": 1, "created_utc": datetime.now(timezone.utc).isoformat(), "kapf_reference": REFERENCE}
    try:
        report["archive"] = inspect(args.input, args.max_metadata_mib * MIB)
        if args.decode_block:
            if not args.decoded_output:
                parser.error("--decoded-output required with --decode-block")
            directory_index, block_index = map(int, args.decode_block.split(":"))
            if min(directory_index, block_index) < 0:
                raise ValueError("indexes must be nonnegative")
            block = report["archive"]["directories"][directory_index]["blocks"][block_index]
            report["decoded_block"] = decode_block(args.input, block, args.decoded_output, args.python_deps, args.max_decoded_mib * MIB)
    except (OSError, ValueError, IndexError, struct.error, ImportError) as error:
        report["error"] = f"{type(error).__name__}: {error}"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    summary = {"shader_entry_count": report.get("archive", {}).get("shader_entry_count"), "decoded_bytes": report.get("decoded_block", {}).get("decoded_bytes"), "error": report.get("error")}
    print(json.dumps(summary, ensure_ascii=False))
    print(f"Report: {args.output.resolve()}")
    return 1 if "error" in report else 0


if __name__ == "__main__":
    raise SystemExit(main())
