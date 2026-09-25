#!/usr/bin/env python3
"""Prepare real COD3 shader containers through bounded KAPF/NCH decoding.

Plans coverage using source name + declared length, then validates/extracts
shader container bytes. Repeated names of equal length may contain different
code, so metadata coverage is not a claim of exhaustive binary coverage.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mmap
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from shader_inventory import container_info
from shader_kapf_inventory import decode_block, inspect

MIB = 1024 * 1024


def save_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def write_identical_or_new(path: Path, data: bytes) -> str:
    digest = hashlib.sha256(data).hexdigest()
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError(f"existing output differs: {path}")
    else:
        with path.open("xb") as stream:
            stream.write(data)
    return digest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game_root", type=Path)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--python-deps", type=Path, default=Path(__file__).resolve().parent.parent / "analysis" / "graphics-python-deps")
    parser.add_argument("--max-decoded-mib", type=int, default=128)
    parser.add_argument("--max-stored-mib", type=int, default=128)
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args()
    if min(args.max_decoded_mib, args.max_stored_mib) < 1:
        parser.error("budgets must be positive")
    root = args.game_root.resolve()
    output_root = args.output_root.resolve()
    if root == output_root or root in output_root.parents:
        parser.error("output must be outside the extracted game directory")
    begin = time.monotonic()
    inventory = {"created_utc": datetime.now(timezone.utc).isoformat(), "archives": [], "errors": []}
    for path in sorted(root.rglob("*.cod")):
        try:
            inventory["archives"].append(inspect(path, 8 * MIB))
        except (OSError, ValueError) as error:
            inventory["errors"].append({"path": str(path), "error": str(error)})
    if not inventory["archives"]:
        inventory["errors"].append({"error": "no KAPF .cod archives found"})
    save_json(output_root / "kapf-inventory.json", inventory)
    if inventory["errors"]:
        print(json.dumps({"errors": inventory["errors"]}))
        return 1

    possibilities = {}
    identities = set()
    for archive in inventory["archives"]:
        for directory in archive["directories"]:
            for entry in directory["shader_entries"]:
                key = (archive["path"], directory["index"], entry["block_index"])
                choice = possibilities.setdefault(key, {"identities": set(), "block": directory["blocks"][entry["block_index"]]})
                identity = (entry["source_name"].lower(), entry["declared_length"])
                choice["identities"].add(identity)
                identities.add(identity)
    remaining = set(identities)
    selected = []
    while remaining:
        key = max(possibilities, key=lambda k: len(possibilities[k]["identities"] & remaining) / max(1, possibilities[k]["block"]["stored_length"]))
        choice = possibilities[key]
        covered = choice["identities"] & remaining
        if not covered:
            raise ValueError("coverage planner made no progress")
        selected.append({"archive": key[0], "directory_index": key[1], "block_index": key[2], "new_metadata_variants": len(covered), "block": choice["block"]})
        remaining -= covered
    plan = {"basis": "greedy coverage of source path plus declared size; equal metadata does not prove equal shader bytes", "source_name_count": len({name for name, size in identities}), "metadata_variant_count": len(identities), "selected_block_count": len(selected), "stored_bytes": sum(s["block"]["stored_length"] for s in selected), "decoded_bytes": sum(s["block"]["uncompressed_length"] for s in selected), "selected_blocks": selected}
    save_json(output_root / "plan.json", plan)
    print(json.dumps({key: plan[key] for key in ("source_name_count", "metadata_variant_count", "selected_block_count", "stored_bytes", "decoded_bytes")}))
    if args.plan_only:
        return 0
    if plan["stored_bytes"] > args.max_stored_mib * MIB or plan["decoded_bytes"] > args.max_decoded_mib * MIB:
        print("Plan exceeds explicit budget; inspect plan.json and choose a deliberate limit.")
        return 2

    manifest = {"schema_version": 1, "created_utc": datetime.now(timezone.utc).isoformat(), "game_root": str(root), "plan": str(output_root / "plan.json"), "coverage_note": plan["basis"], "shader_instruction_validation": "pending XenosRecomp and DXC", "active_renderer_uses_artifacts": False, "blocks": [], "shaders": [], "rejected_candidates": [], "errors": []}
    unique = {}
    for index, choice in enumerate(selected):
        source = Path(choice["archive"])
        stem = hashlib.sha256(str(source.relative_to(root)).encode("utf-8")).hexdigest()[:16]
        stem += f"_d{choice['directory_index']}_b{choice['block_index']}"
        target = output_root / "blocks" / f"{stem}.apkf"
        block = choice["block"]
        try:
            if block["compressed"]:
                receipt = decode_block(source, block, target, args.python_deps, args.max_decoded_mib * MIB)
            else:
                with source.open("rb") as stream:
                    stream.seek(block["offset"])
                    data = stream.read(block["uncompressed_length"])
                if len(data) != block["uncompressed_length"] or not data.startswith(b"APKF"):
                    raise ValueError("uncompressed block is not the expected APKF span")
                digest = write_identical_or_new(target, data)
                receipt = {"method": "exact uncompressed APKF block copy", "output": str(target), "decoded_bytes": len(data), "sha256": digest}
            block_record = {"archive": str(source), "directory_index": choice["directory_index"], "block_index": choice["block_index"], "source_offset": block["offset"], **receipt}
            manifest["blocks"].append(block_record)
            with target.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
                size = len(data)
                cursor = 0
                while (cursor := data.find(b"\x10\x2a", cursor)) >= 0:
                    candidate = container_info(data, cursor, size, include_legacy=True)
                    cursor += 2
                    if candidate is None:
                        continue
                    origin = {"archive": str(source), "directory_index": choice["directory_index"], "block_index": choice["block_index"], "decoded_block": str(target), "offset": candidate["offset"], "offset_hex": candidate["offset_hex"]}
                    if not candidate["metadata_bounds_pass"]:
                        manifest["rejected_candidates"].append({"origin": origin, **candidate})
                        continue
                    container = data[candidate["offset"]:candidate["offset"] + candidate["total_size"]]
                    digest = hashlib.sha256(container).hexdigest()
                    if digest in unique:
                        unique[digest]["origins"].append(origin)
                        continue
                    shader_path = output_root / "containers" / f"{candidate['stage']}_{digest}.bin"
                    write_identical_or_new(shader_path, container)
                    record = {"sha256": digest, "path": str(shader_path), "origins": [origin], **candidate}
                    unique[digest] = record
                    manifest["shaders"].append(record)
        except (OSError, ValueError, IndexError, ImportError) as error:
            manifest["errors"].append({"archive": str(source), "block_index": choice["block_index"], "error": f"{type(error).__name__}: {error}"})
        print(f"Prepared block {index + 1}/{len(selected)}; unique containers: {len(unique)}", flush=True)
    manifest.update(unique_shader_count=len(unique), pixel_shader_count=sum(c["stage"] == "pixel" for c in unique.values()), vertex_shader_count=sum(c["stage"] == "vertex" for c in unique.values()), total_container_bytes=sum(c["total_size"] for c in unique.values()), elapsed_seconds=round(time.monotonic() - begin, 3))
    save_json(output_root / "manifest.json", manifest)
    print(json.dumps({key: manifest[key] for key in ("unique_shader_count", "pixel_shader_count", "vertex_shader_count", "total_container_bytes", "elapsed_seconds", "errors")}))
    return 1 if manifest["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
