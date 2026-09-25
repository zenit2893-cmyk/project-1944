#!/usr/bin/env python3
"""Small, dependency-free oracle for the CoD3 Xenos gradient adapter.

The shader-side implementation is adapted from the pinned Xenia GPU
translator.  This file is an independent numerical check of the contracts;
it does not run Xenia, an emulator, or the game.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
XENOS_COMMON = ROOT / "tools/XenosRecomp/XenosRecomp/shader_common.h"
XENOS_RECOMPILER = ROOT / "tools/XenosRecomp/XenosRecomp/shader_recompiler.cpp"
XENIA_NOTICE = ROOT / "tools/XenosRecomp/XENIA-GRADIENT-NOTICE.txt"
XENIA_LICENSE = ROOT / "tools/XenosRecomp/XENIA-GRADIENT-LICENSE"
XENIA_COMMIT = "0e1307bd2e6bfeeff29635a6b823e72e61c97ce9"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def signed_field(value: int, shift: int, width: int) -> int:
    """Match Xenia's signed bit-field extraction from a uint32 word."""

    mask = (1 << width) - 1
    result = (value >> shift) & mask
    sign = 1 << (width - 1)
    return result - (1 << width) if result & sign else result


def gradient_layout(dx: tuple[float, float], dy: tuple[float, float]) -> tuple[float, float, float, float]:
    """Xenos getGradients result: XZ=ddx(source.xy), YW=ddy(source.xy)."""

    return dx[0], dy[0], dx[1], dy[1]


def cube_from_decoded_source(src: tuple[float, float, float, float]) -> tuple[float, float, float, float]:
    """Reference for cube ALU after the .zzxy source decode.

    Xenia's cube translator receives source.zzxy.  The shader helper selects
    src.zwx to recover the original (x, y, z) direction before applying the
    major-axis and face equations.
    """

    x, y, z = src[2], src[3], src[0]
    if abs(z) >= abs(x) and abs(z) >= abs(y):
        return -y, (-x if z < 0.0 else x), 2.0 * z, (5.0 if z < 0.0 else 4.0)
    if abs(y) >= abs(x):
        return (-z if y < 0.0 else z), x, 2.0 * y, (3.0 if y < 0.0 else 2.0)
    return -y, (z if x < 0.0 else -z), 2.0 * x, (1.0 if x < 0.0 else 0.0)


def cube_direction(coord: tuple[float, float, float]) -> tuple[float, float, float]:
    """Reference for Xenia's inverse SC/TC/face projection."""

    s, t = coord[0] * 2.0 - 3.0, coord[1] * 2.0 - 3.0
    face = min(int(coord[2]), 5)
    negative = (face & 1) != 0
    axis = face >> 1
    if axis == 0:
        return (-1.0 if negative else 1.0), -t, (s if negative else -s)
    if axis == 1:
        return s, (-1.0 if negative else 1.0), (-t if negative else t)
    return (-s if negative else s), -t, (-1.0 if negative else 1.0)


def gradient_scales(fetch_word4: int, register_and_instruction_lod: float) -> tuple[float, float]:
    """Reference for fetch word 4 LOD and horizontal/vertical exponents."""

    sampler_bias = signed_field(fetch_word4, 12, 10)
    horizontal_exponent = signed_field(fetch_word4, 22, 5)
    vertical_exponent = signed_field(fetch_word4, 27, 5)
    lod = register_and_instruction_lod + sampler_bias / 32.0
    return 2.0 ** (lod + horizontal_exponent), 2.0 ** (lod + vertical_exponent)


def source_contract_checks() -> dict[str, int]:
    common = XENOS_COMMON.read_text(encoding="utf-8")
    recompiler = XENOS_RECOMPILER.read_text(encoding="utf-8")
    notice = XENIA_NOTICE.read_text(encoding="utf-8")
    gradient_block = common.split("// BEGIN COD3_GRADIENT_HELPERS", 1)[1].split("// END COD3_GRADIENT_HELPERS", 1)[0]
    require(XENIA_LICENSE.is_file(), "Xenia BSD license file is missing")
    require(XENIA_COMMIT in notice, "gradient notice is not pinned to the Xenia source revision")
    for token in (
        "ddx_coarse(source)",
        "ddy_coarse(source)",
        "return float4(horizontal.x, vertical.x, horizontal.y, vertical.y)",
        "abs(v.z) >= abs(v.x) && abs(v.z) >= abs(v.y)",
        "v.z < 0.0 ? 5.0 : 4.0",
        "v.y < 0.0 ? 3.0 : 2.0",
        "v.x < 0.0 ? 1.0 : 0.0",
        "coord.xy * 2.0 - 3.0",
        "texture.SampleGrad",
        "g_CoD3TextureFetchWord4[8]",
        "int samplerBias",
        "int horizontalExponent",
        "int verticalExponent",
    ):
        require(token in common, f"shader_common.h is missing contract token: {token}")
    require("SampleLevel" not in gradient_block, "gradient helper regressed to an explicit LOD-only sample")
    require("return 0.0" not in gradient_block, "gradient helper regressed to a no-op")
    for token in (
        "FetchOpcode::GetTextureGradients",
        "FetchOpcode::SetTextureGradientsHorz",
        "FetchOpcode::SetTextureGradientsVert",
        "out += \"tfetch\"",
        "out += \"GradCoD3\"",
        "g_CoD3TextureFetchWord4[{}]",
    ):
        require(token in recompiler, f"shader_recompiler.cpp is missing contract token: {token}")
    return {
        "common_required_tokens": 13,
        "recompiler_required_tokens": 6,
        "xenia_commit": XENIA_COMMIT,
    }


def numerical_checks() -> dict[str, int]:
    require(gradient_layout((5.0, -7.0), (2.0, 3.0)) == (5.0, 2.0, -7.0, 3.0), "getGradients XZ/YW layout")

    vectors = (
        ((1.0, 0.25, -0.5), (-0.25, 0.5, 2.0, 0.0)),
        ((-1.0, 0.25, -0.5), (-0.25, -0.5, -2.0, 1.0)),
        ((0.25, 1.0, -0.5), (-0.5, 0.25, 2.0, 2.0)),
        ((0.25, -1.0, -0.5), (0.5, 0.25, -2.0, 3.0)),
        ((0.25, -0.5, 1.0), (0.5, 0.25, 2.0, 4.0)),
        ((0.25, -0.5, -1.0), (0.5, -0.25, -2.0, 5.0)),
        ((1.0, 1.0, 1.0), (-1.0, 1.0, 2.0, 4.0)),
        ((1.0, 1.0, 0.5), (0.5, 1.0, 2.0, 2.0)),
        ((1.0, 0.5, 0.5), (-0.5, -0.5, 2.0, 0.0)),
    )
    for direction, expected in vectors:
        decoded = (direction[2], direction[2], direction[0], direction[1])
        actual = cube_from_decoded_source(decoded)
        require(all(math.isclose(a, b, rel_tol=0.0, abs_tol=1e-7) for a, b in zip(actual, expected)),
                f"cube projection mismatch for {direction}: {actual} != {expected}")

    inverse_cases = (
        ((1.5, 1.75, 0.0), (1.0, -0.5, 0.0)),
        ((1.5, 1.75, 1.0), (-1.0, -0.5, 0.0)),
        ((1.5, 1.75, 2.0), (0.0, 1.0, 0.5)),
        ((1.5, 1.75, 3.0), (0.0, -1.0, -0.5)),
        ((1.5, 1.75, 4.0), (0.0, -0.5, 1.0)),
        ((1.5, 1.75, 5.0), (0.0, -0.5, -1.0)),
    )
    for coord, expected in inverse_cases:
        actual = cube_direction(coord)
        require(all(math.isclose(a, b, rel_tol=0.0, abs_tol=1e-7) for a, b in zip(actual, expected)),
                f"cube inverse mismatch for {coord}: {actual} != {expected}")

    word = ((-17 & 0x3FF) << 12) | ((-2 & 0x1F) << 22) | ((3 & 0x1F) << 27)
    require(signed_field(word, 12, 10) == -17, "word4 signed LOD bias")
    require(signed_field(word, 22, 5) == -2, "word4 signed horizontal exponent")
    require(signed_field(word, 27, 5) == 3, "word4 signed vertical exponent")
    scales = gradient_scales(word, 1.0)
    require(math.isclose(scales[0], 2.0 ** (1.0 - 17.0 / 32.0 - 2.0), abs_tol=1e-12), "word4 horizontal scale")
    require(math.isclose(scales[1], 2.0 ** (1.0 - 17.0 / 32.0 + 3.0), abs_tol=1e-12), "word4 vertical scale")

    return {
        "gradient_layout_cases": 1,
        "cube_projection_cases": len(vectors),
        "cube_inverse_cases": len(inverse_cases),
        "fetch_word4_cases": 4,
    }


def generated_artifact_checks(artifact_dir: Path, batch_report: Path) -> dict[str, object]:
    report = json.loads(batch_report.read_text(encoding="utf-8-sig"))
    summary = report["summary"]
    require(summary["total"] == 610, f"expected 610 entries, got {summary['total']}")
    for key in ("passed_all_stages", "hlsl_passed", "dxil_passed", "spirv_passed"):
        require(summary[key] == 610, f"{key} did not pass for all entries")
    require(summary.get("entries_with_known_semantic_blockers") == 0, "active gradient blockers remain")
    require(report.get("runtime_integration") is False, "compiler report must not claim runtime integration")
    require(report.get("rendering_correctness_verified") is False, "compiler report must not claim rendering correctness")

    hlsl_files = sorted(artifact_dir.glob("*.hlsl"))
    require(len(hlsl_files) == 610, f"expected 610 HLSL artifacts, got {len(hlsl_files)}")
    # The generated file contains the shared helper definitions before the
    # entry point.  Count only the emitted guest program so helper declarations
    # cannot look like extra fetch instructions.
    body_text = "\n".join(path.read_text(encoding="utf-8").split("void main(", 1)[-1] for path in hlsl_files)
    require("#error Unsupported_CoD3_texture_gradient_variant" not in body_text, "fail-closed gradient emission remains")

    audit = json.loads((ROOT / "analysis/graphics-texture-feature-inventory.json").read_text(encoding="utf-8-sig"))
    expected_get = expected_set_h = expected_set_v = expected_samples = 0
    expected_slots: list[int] = []
    for entry in audit["entries"]:
        for instruction in entry["texture_instructions"]:
            opcode = instruction["opcode"]
            if opcode == 18:
                expected_get += 1
            elif opcode == 25:
                expected_set_h += 1
            elif opcode == 26:
                expected_set_v += 1
            elif opcode == 1 and instruction["use_register_gradients"]:
                expected_samples += 1
                expected_slots.append(instruction["sampler_index"])

    def count(pattern: str) -> int:
        return len(re.findall(pattern, body_text, flags=re.MULTILINE))

    actual_get = count(r"\bgetTextureGradientsCoD3\(")
    actual_set_h = count(r"^\s*texGradH = ")
    actual_set_v = count(r"^\s*texGradV = ")
    actual_2d = count(r"\btfetch2DGradCoD3\(")
    actual_cube = count(r"\btfetchCubeGradCoD3\(")
    actual_word4 = re.findall(r"g_CoD3TextureFetchWord4\[(\d+)\]\.([xyzw])", body_text)
    actual_slots = [int(row) * 4 + "xyzw".index(component) for row, component in actual_word4]
    require(actual_get == expected_get == 332, f"getGradients count {actual_get} != {expected_get}")
    require(actual_set_h == expected_set_h == 30, f"setGradH count {actual_set_h} != {expected_set_h}")
    require(actual_set_v == expected_set_v == 30, f"setGradV count {actual_set_v} != {expected_set_v}")
    require(actual_2d + actual_cube == expected_samples == 36, "SampleGrad count or dimension split")
    require(sorted(actual_slots) == sorted(expected_slots), "SampleGrad calls do not use the real guest sampler slots")
    require(all(record.get("input_unchanged") for record in report["shaders"]), "a source container changed during batch")
    require(not any(record.get("known_semantic_blockers") for record in report["shaders"]), "report contains semantic blockers")

    return {
        "hlsl_artifacts": len(hlsl_files),
        "counts": {
            "get_texture_gradients": actual_get,
            "set_gradients_horizontal": actual_set_h,
            "set_gradients_vertical": actual_set_v,
            "sample_grad_2d": actual_2d,
            "sample_grad_cube": actual_cube,
            "word4_references": len(actual_slots),
        },
        "source_containers_unchanged": True,
        "known_semantic_blockers": 0,
        "batch_summary": summary,
    }


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: gradient_semantics.py <artifact-dir> <batch-report> <result-json>", file=sys.stderr)
        return 2
    artifact_dir, batch_report, result_path = map(Path, sys.argv[1:])
    try:
        result = {
            "passed": True,
            "xenia_source_commit": XENIA_COMMIT,
            "source_contract": source_contract_checks(),
            "numerical_oracle": numerical_checks(),
            "generated_artifacts": generated_artifact_checks(artifact_dir, batch_report),
        }
    except (AssertionError, OSError, KeyError, json.JSONDecodeError, ValueError) as error:
        result = {"passed": False, "error": str(error)}
        result_path.parent.mkdir(parents=True, exist_ok=True)
        result_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result), file=sys.stderr)
        return 1
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
