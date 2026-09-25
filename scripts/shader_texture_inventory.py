#!/usr/bin/env python3
"""Inspect active texture-fetch instructions in prepared COD3 shader entries.

Only instructions referenced as FETCH by control-flow EXEC sequence bits are
included. Bit layouts follow XenosRecomp/shader_code.h. This is a static feature
inventory, not an emulator or shader-equivalence validator.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import struct
from pathlib import Path

EXEC_OPS = {1, 2, 3, 4, 5, 6, 13, 14}
FETCH_NAMES = {1: "TextureFetch", 16: "GetTextureBorderColorFrac", 17: "GetTextureComputedLod", 18: "GetTextureGradients", 19: "GetTextureWeights", 24: "SetTextureLod", 25: "SetTextureGradientsHorz", 26: "SetTextureGradientsVert"}


def signed(value: int, bits: int) -> int:
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def texture_instructions(blob: bytes, shader_offset: int) -> dict:
    virtual, physical = struct.unpack_from(">2I", blob, 4)
    code_offset, size = struct.unpack_from(">2I", blob, shader_offset)
    if code_offset + size > physical or size % 12:
        raise ValueError("invalid microcode span")
    base = virtual + code_offset
    control_flow_limit = size
    position = 0
    fetched = {}
    while position < control_flow_limit:
        first, middle, last = struct.unpack_from(">3I", blob, base + position)
        for cf in (first | ((middle & 0xFFFF) << 32), (middle >> 16) | (last << 16)):
            opcode = (cf >> 44) & 15
            if opcode not in EXEC_OPS:
                continue
            address = cf & 4095
            count = (cf >> 12) & 7
            sequence = (cf >> 16) & 4095
            if address:
                control_flow_limit = min(control_flow_limit, address * 12)
            if (address + count) * 12 > size:
                raise ValueError("EXEC references instruction outside microcode")
            for index in range(count):
                if not (sequence >> (index * 2)) & 1:
                    continue
                instruction_address = address + index
                w0, w1, w2 = struct.unpack_from(">3I", blob, base + instruction_address * 12)
                fetch_opcode = w0 & 31
                if fetch_opcode == 0:
                    continue
                instruction = {"instruction_address": instruction_address, "opcode": fetch_opcode, "operation": FETCH_NAMES.get(fetch_opcode, "unknown"), "raw_words": [f"{w:08X}" for w in (w0, w1, w2)], "sampler_index": (w0 >> 20) & 31, "source_register": (w0 >> 5) & 63, "source_register_relative": (w0 >> 11) & 1, "source_swizzle": (w0 >> 26) & 63, "use_computed_lod": (w1 >> 28) & 1, "use_register_lod": (w1 >> 29) & 1, "use_register_gradients": w2 & 1, "is_predicated": (w1 >> 31) & 1, "lod_bias_raw": signed((w2 >> 2) & 127, 7), "dimension": (w2 >> 14) & 3, "mag_filter": (w1 >> 12) & 3, "min_filter": (w1 >> 14) & 3, "mip_filter": (w1 >> 16) & 3, "aniso_filter": (w1 >> 18) & 7, "arbitrary_filter": (w1 >> 21) & 7, "volume_mag_filter": (w1 >> 24) & 3, "volume_min_filter": (w1 >> 26) & 3, "sample_location": (w2 >> 1) & 1, "offset_x_raw": signed((w2 >> 16) & 31, 5), "offset_y_raw": signed((w2 >> 21) & 31, 5), "offset_z_raw": signed((w2 >> 26) & 31, 5)}
                if fetch_opcode == 24:
                    instruction["set_lod_source"] = f"r{instruction['source_register']}.{'xyzw'[instruction['source_swizzle'] & 3]}"
                fetched[instruction_address] = instruction
        position += 12
    return {"shader_header_offset": shader_offset, "microcode_bytes": size, "control_flow_bytes": control_flow_limit, "microcode_sha256": hashlib.sha256(blob[base:base + size]).hexdigest(), "texture_instructions": [fetched[k] for k in sorted(fetched)]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prepared = json.loads(args.manifest.read_text(encoding="utf-8"))
    report = {"schema_version": 1, "source_manifest": str(args.manifest.resolve()), "source_manifest_sha256": hashlib.sha256(args.manifest.read_bytes()).hexdigest(), "method": "CF EXEC referenced FETCH instructions only; bit layouts from XenosRecomp shader_code.h", "entries": [], "errors": []}
    op_counts = collections.Counter()
    feature_counts = collections.Counter()
    for container in prepared["shaders"]:
        path = Path(container["path"])
        try:
            blob = path.read_bytes()
            if hashlib.sha256(blob).hexdigest() != container["sha256"]:
                raise ValueError("container hash mismatch")
            entries = [("single", container["shader_offset"])]
            if container["flags"] == "0x102A1021":
                entries = [("primary", container["shader_offset"]), ("secondary", container["auxiliary_offsets"][1])]
            for name, shader_offset in entries:
                record = {"sha256": container["sha256"], "stage": container["stage"], "entry": name, **texture_instructions(blob, shader_offset)}
                report["entries"].append(record)
                for instruction in record["texture_instructions"]:
                    op_counts[instruction["operation"]] += 1
                    if instruction["opcode"] == 1:
                        for feature in ("use_register_lod", "use_register_gradients", "source_register_relative", "is_predicated"):
                            if instruction[feature]:
                                feature_counts[feature] += 1
                        if instruction["lod_bias_raw"]:
                            feature_counts["nonzero_instruction_lod_bias"] += 1
                        if any(instruction[k] for k in ("offset_x_raw", "offset_y_raw", "offset_z_raw")):
                            feature_counts["nonzero_sample_offsets"] += 1
        except (OSError, ValueError, struct.error) as error:
            report["errors"].append({"path": str(path), "error": str(error)})
    report["summary"] = {"entries": len(report["entries"]), "operation_counts": dict(op_counts), "texture_feature_instruction_counts": dict(feature_counts), "errors": len(report["errors"])}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(report["summary"]))
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
