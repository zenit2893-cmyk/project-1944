"""Validate extracted, unmodified CoD3 shader containers with XenosRecomp and DXC.

Outputs are compiler artifacts and a provenance report, not a runtime shader cache.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent.parent


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def relative(path: Path) -> str:
    return str(path.resolve().relative_to(ROOT))


def attach_semantic_audit(report: dict, audit_path: Path) -> None:
    """Compiler acceptance must not hide observed unsupported guest operations."""
    report["semantics_verified"] = False
    if not audit_path.is_file():
        report["semantic_audit_status"] = "unavailable; compiler success alone does not establish shader behavior"
        return
    audit = json.loads(audit_path.read_text(encoding="utf-8-sig"))
    if audit["source_manifest_sha256"] != report["source_manifest_sha256"]:
        raise ValueError("Semantic audit and compiler report refer to different extraction manifests")
    entries = {(entry["sha256"], entry["entry"]): entry for entry in audit["entries"]}
    blocked = 0
    for shader in report["shaders"]:
        features = entries[(shader["sha256"], shader["entry"])]
        gradients = [instruction for instruction in features["texture_instructions"]
                     if instruction["opcode"] in (18, 25, 26) or
                     (instruction["opcode"] == 1 and instruction["use_register_gradients"])]
        hlsl_path = Path(shader.get("hlsl", {}).get("artifact", ""))
        hlsl = hlsl_path.read_text(encoding="utf-8") if hlsl_path.is_file() else ""
        implemented = "#define COD3_TEXTURE_GRADIENT_SEMANTICS 1\n" in hlsl
        unsupported = gradients if not implemented or "#error Unsupported_CoD3_texture_gradient_variant" in hlsl else []
        shader["known_semantic_blockers"] = [
            {"instruction_address": instruction["instruction_address"], "operation": instruction["operation"],
             "reason": "register-gradient sampling is not implemented" if instruction["opcode"] == 1
             else "this active gradient instruction is not emitted by the converter"}
            for instruction in unsupported
        ]
        shader["semantics_verified"] = False
        if implemented:
            shader["gradient_translation"] = "Xenia-derived coarse getGradients, persistent swizzled setGradients, 2D/cube SampleGrad; native helper tests are separate evidence"
            if any(instruction["opcode"] == 1 for instruction in gradients):
                shader["gradient_runtime_requirements"] = [
                    "Bind CoD3TextureFetchConstants: 32 raw guest fetch word 4 values, 128 bytes at b3 space4",
                    "Bind guest filtering, clamp, anisotropy and base-map state; no assumed zero fetch state",
                    "Validate dynamic branch/predicate derivative behavior in actual rendering",
                ]
        blocked += bool(unsupported)
    report["semantic_audit_status"] = ("active gradient translation checked from each emitted artifact; runtime binding and rendering remain unverified"
                                       if not blocked else "active gradient operations expose known semantic gaps despite compiler success")
    report["semantic_audit"] = str(audit_path.resolve())
    report["semantic_audit_sha256"] = digest(audit_path)
    report["semantic_feature_summary"] = audit["summary"]
    report["summary"]["entries_with_known_semantic_blockers"] = blocked


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=ROOT / "analysis/graphics-prepared/manifest.json")
    parser.add_argument("--output", type=Path, default=ROOT / "tools/XenosRecomp/build-cod3-shaders")
    parser.add_argument("--report", type=Path, default=ROOT / "docs/reports/xenos-cod3-shaders.json")
    parser.add_argument("--workers", type=int, choices=range(1, 9), default=4)
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--semantic-audit", type=Path, default=ROOT / "analysis/graphics-texture-feature-inventory.json")
    parser.add_argument("--refresh-semantics-only", action="store_true", help="Update semantic metadata on an existing report without rerunning compilers")
    options = parser.parse_args()
    if options.refresh_semantics_only:
        report = json.loads(options.report.read_text(encoding="utf-8-sig"))
        attach_semantic_audit(report, options.semantic_audit)
        options.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(json.dumps(report["summary"]))
        return 0
    source_manifest = json.loads(options.manifest.read_text(encoding="utf-8-sig"))
    containers = source_manifest["shaders"]
    shaders = []
    for container in containers:
        entries = ("primary", "secondary") if container["flags"] == "0x102A1021" else ("single",)
        shaders.extend(dict(container, entry=entry) for entry in entries)
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    xenos = ROOT / "tools/XenosRecomp/build/XenosRecomp/XenosRecomp.exe"
    dxc = ROOT / "tools/XenosRecomp/thirdparty/dxc-bin/bin/x64/dxc.exe"
    header = ROOT / "tools/XenosRecomp/XenosRecomp/shader_common.h"
    for required in (xenos, dxc, header):
        if not required.is_file():
            parser.error(f"Missing required tool/file: {required}")

    started = time.monotonic()

    def run_step(command: list[str], name: str, stem: str, artifact: Path) -> dict:
        log_file = output / f"{stem}.{name}.log"
        begin = time.monotonic()
        try:
            result = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=options.timeout)
            combined = result.stdout + result.stderr
            log_file.write_bytes(combined)
            record = {"exit_code": result.returncode, "elapsed_seconds": round(time.monotonic() - begin, 3)}
        except subprocess.TimeoutExpired as error:
            log_file.write_bytes((error.stdout or b"") + (error.stderr or b""))
            record = {"exit_code": None, "timed_out": True, "elapsed_seconds": options.timeout}
        record["command"] = command
        record["log"] = str(log_file)
        record["passed"] = record["exit_code"] == 0 and artifact.is_file() and artifact.stat().st_size > 0
        if record["passed"]:
            record.update(artifact=str(artifact), bytes=artifact.stat().st_size, sha256=digest(artifact))
        else:
            record["error_excerpt"] = log_file.read_text(encoding="utf-8", errors="replace")[:2000]
        return record

    def convert(shader: dict) -> dict:
        path = Path(shader["path"])
        source_hash = digest(path)
        record = {"source": str(path), "sha256": source_hash, "stage": shader["stage"], "flags": shader["flags"], "entry": shader["entry"]}
        if source_hash != shader["sha256"]:
            return dict(record, passed=False, error="Input hash does not match extraction manifest")
        stem = f"{shader['stage']}_{source_hash}_{shader['entry']}"
        input_bytes = path.read_bytes()
        secondary = shader["entry"] == "secondary"
        record["shader_header_offset"] = int.from_bytes(input_bytes[0x20:0x24] if secondary else input_bytes[0x18:0x1C], "big")
        record["definition_table_offset"] = int.from_bytes(input_bytes[0x1C:0x20] if secondary else input_bytes[0x14:0x18], "big")
        entry_option = "--cod3-legacy-container" if shader["entry"] == "single" else f"--cod3-legacy-{shader['entry']}"
        hlsl, dxil, spirv = (output / f"{stem}.{extension}" for extension in ("hlsl", "dxil", "spv"))
        record["hlsl"] = run_step(
            [str(xenos), relative(path), relative(hlsl), relative(header), entry_option],
            "xenos", stem, hlsl,
        )
        if record["hlsl"]["passed"]:
            hlsl_text = hlsl.read_text(encoding="utf-8")
            record["vertex_input_bindings"] = [
                {"fetch_instruction_address": int(address), "guest_usage": int(usage), "guest_usage_index": int(index),
                 "vulkan_location": int(location), "d3d_semantic": "FETCH", "d3d_semantic_index": int(address)}
                for address, usage, index, location in re.findall(r"COD3_FETCH address=(\d+) usage=(\d+) usage_index=(\d+) location=(\d+)", hlsl_text)
            ]
            record["dxil"] = run_step(
                [str(dxc), "-T", "lib_6_3", "-HV", "2021", "-all-resources-bound",
                 "-Wno-ignored-attributes", "-Qstrip_reflect", "-Qstrip_debug", "-Fo", relative(dxil), relative(hlsl)],
                "dxil", stem, dxil,
            )
            spirv_command = [str(dxc), "-T", "ps_6_0" if shader["stage"] == "pixel" else "vs_6_0",
                             "-E", "main", "-HV", "2021", "-all-resources-bound", "-spirv",
                             "-fvk-use-dx-layout", "-Qstrip_debug", "-Fo", relative(spirv), relative(hlsl)]
            if shader["stage"] == "vertex":
                spirv_command.append("-fvk-invert-y")
            record["spirv"] = run_step(spirv_command, "spirv", stem, spirv)
        record["input_unchanged"] = digest(path) == source_hash
        record["passed"] = record["input_unchanged"] and all(record.get(stage, {}).get("passed", False) for stage in ("hlsl", "dxil", "spirv"))
        return record

    results = []
    with ThreadPoolExecutor(max_workers=options.workers) as executor:
        futures = [executor.submit(convert, shader) for shader in shaders]
        for future in as_completed(futures):
            results.append(future.result())
            if len(results) % 50 == 0 or len(results) == len(shaders):
                print(f"Validated {len(results)}/{len(shaders)}; passed {sum(r['passed'] for r in results)}", flush=True)
    results.sort(key=lambda result: (result["stage"], result["sha256"], result["entry"]))
    summary = {
        "containers": len(containers), "total": len(results), "passed_all_stages": sum(r["passed"] for r in results),
        "failed": sum(not r["passed"] for r in results),
        "hlsl_passed": sum(r.get("hlsl", {}).get("passed", False) for r in results),
        "dxil_passed": sum(r.get("dxil", {}).get("passed", False) for r in results),
        "spirv_passed": sum(r.get("spirv", {}).get("passed", False) for r in results),
    }
    report = {
        "schema_version": 1, "created_utc": datetime.now(timezone.utc).isoformat(),
        "source_manifest": str(options.manifest.resolve()), "source_manifest_sha256": digest(options.manifest),
        "input_coverage_note": source_manifest.get("coverage_note"),
        "xenos_executable": str(xenos), "xenos_executable_sha256": digest(xenos),
        "dxc_executable": str(dxc), "dxc_executable_sha256": digest(dxc),
        "legacy_adapter": "explicit CoD3 options; 0x102A1021 converted separately as primary+secondary with unchanged input; definition list at +0x20",
        "vertex_input_contract": "FETCH semantic indices identify original microcode instruction addresses, not host buffers; preserve all inputs and resolve guest vertex-declaration patching at runtime",
        "entry_selection_runtime_semantics_verified": False,
        "dxil_artifact_type": "Shader Model 6.3 library; runtime specialization/linking is still required",
        "spirv_artifact_type": "Shader Model 6.0 vertex/pixel entry point via DXC SPIR-V backend",
        "runtime_integration": False, "rendering_correctness_verified": False,
        "workers": options.workers, "timeout_per_process_seconds": options.timeout,
        "elapsed_seconds": round(time.monotonic() - started, 3), "summary": summary, "shaders": results,
    }
    attach_semantic_audit(report, options.semantic_audit)
    options.report.parent.mkdir(parents=True, exist_ok=True)
    options.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(summary), flush=True)
    print(f"Report: {options.report}", flush=True)
    return 0 if not summary["failed"] else 1


if __name__ == "__main__":
    sys.exit(main())
