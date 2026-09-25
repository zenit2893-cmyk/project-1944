#!/usr/bin/env python3
"""Bounded, read-only inventory of possible Xbox 360 shader containers.

The signature/header layout follows hedge-dev/XenosRecomp at
990d03b28a27b50277ee5d8d942e1c5f873869d1 (shader.h and main.cpp).
This is a container locator, not a shader instruction validator or archive
decompressor. A hit is never counted as a successfully translated shader.
Only --extract-dir copies candidate bytes; original inputs are never written.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import mmap
import struct
import time
from datetime import datetime, timezone
from pathlib import Path

MIB = 1024 * 1024
PREFIX = b"\x10\x2a"
HEADER = struct.Struct(">9I")
SOURCE = "https://github.com/hedge-dev/XenosRecomp/tree/990d03b28a27b50277ee5d8d942e1c5f873869d1"


def container_info(data: mmap.mmap, offset: int, size: int, include_legacy: bool = False) -> dict | None:
    if offset + HEADER.size > size:
        return None
    flags, virtual, physical, field_c, ctab, definitions, shader, pad1, pad2 = HEADER.unpack_from(data, offset)
    total = virtual + physical
    revision = flags & 0xFFFFFF00
    if revision not in ((0x102A1100, 0x102A1000) if include_legacy else (0x102A1100,)):
        return None
    if revision == 0x102A1100 and (pad1 or pad2):
        return None
    if total < HEADER.size or total > size - offset:
        return None
    info = {
        "offset": offset,
        "offset_hex": f"0x{offset:X}",
        "upstream_4_byte_aligned": offset % 4 == 0,
        "flags": f"0x{flags:08X}",
        "container_revision": "legacy_0x10_observed_in_cod3" if revision == 0x102A1000 else "upstream_0x11",
        "upstream_version_accepted": revision == 0x102A1100,
        "auxiliary_offsets": [pad1, pad2],
        "stage": "vertex" if flags & 1 else "pixel",
        "virtual_size": virtual,
        "physical_size": physical,
        "total_size": total,
        "constant_table_offset": ctab,
        "definition_table_offset": definitions,
        "shader_offset": shader,
        "field_c": field_c,
    }
    problems = []
    if revision == 0x102A1000:
        for auxiliary in (pad1, pad2):
            if auxiliary and (auxiliary < HEADER.size or auxiliary >= virtual):
                problems.append("legacy auxiliary metadata offset outside virtual section")
    if virtual < HEADER.size:
        problems.append("virtual section smaller than container header")
    if not physical:
        problems.append("empty physical section")
    shader_header_size = 36 if flags & 1 else 32
    if shader < HEADER.size or shader + shader_header_size > virtual:
        problems.append("shader metadata does not fit virtual section")
    else:
        code_offset, code_size = struct.unpack_from(">2I", data, offset + shader)
        info.update(microcode_physical_offset=code_offset, microcode_size=code_size)
        if code_size == 0 or code_offset + code_size > physical:
            problems.append("microcode does not fit physical section")
        if code_size % 12:
            problems.append("microcode byte length is not a multiple of 12")
        if flags & 1:
            skip, count = struct.unpack_from(">2I", data, offset + shader + 24)
            info["vertex_element_count"] = count
            if shader + 36 + (skip + count) * 4 > virtual:
                problems.append("vertex declarations do not fit virtual section")
    if not ctab:
        info["reflection_present"] = False
    elif ctab < HEADER.size or ctab + 32 > virtual:
        info["reflection_present"] = False
        problems.append("constant table header does not fit virtual section")
    else:
        info["reflection_present"] = True
        _, table_size, creator, version, count, constants, table_flags, target = struct.unpack_from(">8I", data, offset + ctab)
        info.update(constant_count=count, constant_table_size=table_size, shader_version=f"0x{version:08X}")
        table_base = ctab + 4
        if table_size < 28 or table_base + table_size > virtual:
            problems.append("constant table size outside virtual section")
        if count and (constants < 28 or table_base + constants + count * 20 > virtual):
            problems.append("constant info array outside virtual section")
        elif count <= 4096:
            register_sets = collections.Counter()
            for index in range(count):
                name, regset, regindex, regcount, reserved, type_offset, default = struct.unpack_from(">I4H2I", data, offset + table_base + constants + index * 20)
                register_sets[str(regset)] += 1
                if name == 0 or table_base + name >= virtual:
                    problems.append(f"constant {index} name outside virtual section")
                    break
                name_end = data.find(b"\0", offset + table_base + name, offset + virtual)
                if name_end < 0:
                    problems.append(f"constant {index} name has no terminator")
                    break
                if type_offset and table_base + type_offset + 16 > virtual:
                    problems.append(f"constant {index} type info outside virtual section")
                    break
            info["constant_register_set_counts"] = dict(register_sets)
        else:
            problems.append("constant count exceeds bounded metadata inspection limit")
    if definitions and (definitions < HEADER.size or definitions + 20 > virtual):
        problems.append("definition table header does not fit virtual section")
    info["metadata_problems"] = problems
    info["metadata_bounds_pass"] = not problems
    info["translation_tested"] = False
    return info


def classify_head(head: bytes) -> str:
    for signature, name in ((b"XEX2", "xex2"), (b"MZ", "pe_mz"), (b"PK\x03\x04", "zip"), (b"KAPF", "kapf_archive"), (b"APKF", "apkf_block"), (b"NCH\0", "nch_chunk"), (b"IWff", "iw_fastfile"), (b"TAff", "treyarch_fastfile"), (b"XSH", "runtime_shader_cache"), (b"DDS ", "dds"), (b"BIK", "bink")):
        if head.startswith(signature):
            return name
    return "unidentified"


def input_files(inputs: list[Path]) -> list[Path]:
    found = set()
    for item in inputs:
        if not item.exists():
            raise FileNotFoundError(item)
        paths = item.rglob("*") if item.is_dir() else [item]
        for path in paths:
            if path.is_file() and not path.is_symlink():
                found.add(path.resolve())
    # Inspect likely shader/metadata files before large bulk assets.
    def priority(path: Path) -> tuple:
        shader_name = any(part in path.name.lower() for part in ("shader", ".xpu", ".xvu", ".psh", ".vsh"))
        executable = path.suffix.lower() in (".xex", ".exe", ".bin", ".pe")
        return (not shader_name, not executable, path.stat().st_size, str(path).lower())
    return sorted(found, key=priority)


def positive(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-total-mib", type=positive, default=512)
    parser.add_argument("--max-file-mib", type=positive, default=16)
    parser.add_argument("--max-candidates", type=positive, default=4096)
    parser.add_argument("--extract-dir", type=Path)
    parser.add_argument("--max-extract", type=positive, default=16)
    parser.add_argument("--max-container-mib", type=positive, default=8)
    parser.add_argument("--include-legacy", action="store_true", help="also inventory observed COD3 0x102A10xx containers; upstream support is not implied")
    args = parser.parse_args()
    start = time.monotonic()
    files = input_files(args.inputs)
    input_set = set(files)
    if args.output.resolve() in input_set:
        parser.error("output must not overwrite an input file")
    total_budget = args.max_total_mib * MIB
    file_budget = args.max_file_mib * MIB
    report = {
        "schema_version": 1,
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "method": "bounded literal signature search plus metadata bounds checks; no decompression or instruction validation",
        "container_reference": SOURCE,
        "inputs": [str(path.resolve()) for path in args.inputs],
        "limits": {"total_scan_bytes": total_budget, "per_file_scan_bytes": file_budget, "max_candidates": args.max_candidates},
        "file_count": len(files),
        "input_bytes": sum(path.stat().st_size for path in files),
        "files": [],
        "candidates": [],
        "errors": [],
    }
    scanned = extracted = 0
    seen_hashes = set()
    for path in files:
        if scanned >= total_budget or len(report["candidates"]) >= args.max_candidates:
            break
        size = path.stat().st_size
        limit = min(size, file_budget, total_budget - scanned)
        entry = {"path": str(path), "size": size, "scan_start": 0, "scan_length": limit, "complete_file_scan": limit == size, "signature_hits": 0, "header_candidates": 0}
        report["files"].append(entry)
        try:
            with path.open("rb") as stream:
                head = stream.read(64)
                entry.update(head_hex=head.hex(), head_ascii="".join(chr(b) if 32 <= b < 127 else "." for b in head), head_type=classify_head(head))
                if not size:
                    continue
                with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
                    cursor = 0
                    while cursor < limit:
                        hit = data.find(PREFIX, cursor, limit)
                        if hit < 0:
                            break
                        entry["signature_hits"] += 1
                        cursor = hit + 1
                        candidate = container_info(data, hit, size, args.include_legacy)
                        if candidate is None:
                            continue
                        entry["header_candidates"] += 1
                        candidate["source_file"] = str(path)
                        candidate["local_extracted_path"] = None
                        report["candidates"].append(candidate)
                        if len(report["candidates"]) >= args.max_candidates:
                            entry["scan_length"] = cursor
                            entry["complete_file_scan"] = cursor == size
                            break
                        if args.extract_dir and candidate["metadata_bounds_pass"] and extracted < args.max_extract and candidate["total_size"] <= args.max_container_mib * MIB:
                            blob = data[hit:hit + candidate["total_size"]]
                            digest = hashlib.sha256(blob).hexdigest()
                            candidate["sha256"] = digest
                            if digest not in seen_hashes:
                                args.extract_dir.mkdir(parents=True, exist_ok=True)
                                target = args.extract_dir / f"{candidate['stage']}_{digest}.bin"
                                if target.resolve() in input_set:
                                    raise ValueError("extraction target would overwrite input")
                                if target.exists():
                                    if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                                        raise ValueError(f"existing extraction has different content: {target}")
                                else:
                                    with target.open("xb") as output:
                                        output.write(blob)
                                candidate["local_extracted_path"] = str(target.resolve())
                                seen_hashes.add(digest)
                                extracted += 1
        except (OSError, ValueError, struct.error) as error:
            report["errors"].append({"path": str(path), "error": str(error)})
        scanned += entry["scan_length"]
    report.update(scanned_bytes=scanned, elapsed_seconds=round(time.monotonic() - start, 3), extracted_unique_containers=extracted, inspected_file_count=len(report["files"]), candidate_count=len(report["candidates"]), metadata_bounds_pass_count=sum(c["metadata_bounds_pass"] for c in report["candidates"]), reflection_present_count=sum(c["reflection_present"] for c in report["candidates"]), all_input_bytes_scanned=scanned == report["input_bytes"])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({key: report[key] for key in ("file_count", "input_bytes", "scanned_bytes", "elapsed_seconds", "candidate_count", "metadata_bounds_pass_count", "reflection_present_count", "extracted_unique_containers", "all_input_bytes_scanned", "errors")}, ensure_ascii=False))
    print(f"Report: {args.output.resolve()}")
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
