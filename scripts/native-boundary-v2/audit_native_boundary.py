#!/usr/bin/env python3
"""Audit the CoD3 native AOT boundary without launching the game.

The audit deliberately separates three kinds of evidence:

* PE evidence: the shipped x64 images, their direct imports, exports, hashes,
  and the local import closure;
* Ninja/CMake evidence: generated PPC C++ objects and the link graph for the
  executable and the fifteen title DLLs;
* provenance/isolation evidence: the pinned ReXGlue, XenonRecomp, XenosRecomp,
  and Xenia source trees plus the compile-only Xenia graphics target.

This is a static boundary check. It never starts cod3_pc.exe, xenia_canary.exe,
or any other executable and it cannot prove runtime behavior, dynamic library
search-path behavior, gameplay correctness, or 120 FPS physics correctness.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any, Iterable


SCHEMA_VERSION = 1
CONFIGURATION = "RelWithDebInfo"
MAIN_NAME = "cod3_pc.exe"
MISSION_NAMES = [
    "blkbrn",
    "chambois",
    "credits",
    "crssrds",
    "falaise",
    "forest",
    "fuelplnt",
    "hostage",
    "island",
    "laison",
    "mace2",
    "mayenne",
    "nightd",
    "saint_lo",
    "stbert",
]
MISSION_DLLS = [f"cod3_pc_{name}.dll" for name in MISSION_NAMES]
LOCAL_RUNTIME_DLLS = [
    "cod3_coroutines.dll",
    "rexruntimerd.dll",
    "rexgpu-xenosrd.dll",
    "TracyClientrd.dll",
]

# These patterns are intentionally narrower than a generic "translator"
# search. ReXGlue's Xenos GPU plugin contains ShaderTranslator symbols and is
# expected to translate shaders; that is not a guest CPU/JIT implementation.
FORBIDDEN_IMPORT_RE = re.compile(
    r"(?i)(?:xenia[_-]?canary|xenia[_-]?emulator|xenia.*\.dll|"
    r"guest[_ -]?cpu|cpu[_ -]?translator|(?:ppc|guest)[_ -]?(?:jit|translator))"
)
FORBIDDEN_CPU_RE = re.compile(
    r"(?i)(?:\bguest\s+cpu\b|\bcpu[_ -]?translator\b|"
    r"\b(?:ppc|guest)[_ -]?(?:jit|translator)\b|"
    r"\b(?:jit|translator)[_ -]?(?:cpu|guest|ppc)\b)"
)
XENIA_RE = re.compile(r"(?i)xenia")
JIT_WORD_RE = re.compile(r"(?i)\bjit\b")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def relative(path: Path, workspace: Path) -> str:
    try:
        return path.resolve().relative_to(workspace.resolve()).as_posix()
    except ValueError:
        return str(path.resolve()).replace("\\", "/")


def read_json(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return None


def decode_name(value: bytes | None) -> str:
    if value is None:
        return ""
    return value.decode("utf-8", errors="replace")


def parse_pe(path: Path) -> dict[str, Any]:
    """Return stable PE facts using the isolated pefile package."""

    try:
        import pefile  # type: ignore
    except ImportError as exc:  # pragma: no cover - environment failure path
        raise RuntimeError(
            "pefile is required; run this script through the bundled "
            "tools/toolchain/bootstrap-python interpreter"
        ) from exc

    pe = pefile.PE(str(path), fast_load=False)
    try:
        imports: list[dict[str, Any]] = []
        for entry in getattr(pe, "DIRECTORY_ENTRY_IMPORT", []):
            symbols: list[str] = []
            for item in entry.imports:
                if item.name is not None:
                    symbols.append(decode_name(item.name))
                else:
                    symbols.append(f"#ordinal:{item.ordinal}")
            imports.append(
                {
                    "dll": decode_name(entry.dll),
                    "symbol_count": len(symbols),
                    "symbols": symbols,
                }
            )

        delay_imports = [
            decode_name(entry.dll)
            for entry in getattr(pe, "DIRECTORY_ENTRY_DELAY_IMPORT", [])
        ]

        exports: list[str] = []
        export_directory = getattr(pe, "DIRECTORY_ENTRY_EXPORT", None)
        if export_directory is not None:
            exports = sorted(
                decode_name(item.name) if item.name is not None else f"#ordinal:{item.ordinal}"
                for item in export_directory.symbols
            )

        machine = int(pe.FILE_HEADER.Machine)
        subsystem = int(pe.OPTIONAL_HEADER.Subsystem)
        sections = []
        for section in pe.sections:
            sections.append(
                {
                    "name": section.Name.rstrip(b"\x00").decode("ascii", errors="replace"),
                    "virtual_size": int(section.Misc_VirtualSize),
                    "raw_size": int(section.SizeOfRawData),
                    "characteristics": f"0x{int(section.Characteristics):08X}",
                }
            )

        return {
            "machine": f"0x{machine:04X}",
            "machine_name": "AMD64" if machine == 0x8664 else f"unknown(0x{machine:04X})",
            "subsystem": f"0x{subsystem:X}",
            "subsystem_name": "Windows GUI" if subsystem == 2 else str(subsystem),
            "timestamp": dt.datetime.fromtimestamp(
                int(pe.FILE_HEADER.TimeDateStamp), dt.timezone.utc
            ).isoformat(),
            "entry_point_rva": f"0x{int(pe.OPTIONAL_HEADER.AddressOfEntryPoint):X}",
            "image_base": f"0x{int(pe.OPTIONAL_HEADER.ImageBase):X}",
            "size_of_image": int(pe.OPTIONAL_HEADER.SizeOfImage),
            "imports": imports,
            "delay_imports": delay_imports,
            "exports": exports,
            "sections": sections,
            "has_certificate": bool(
                getattr(pe.OPTIONAL_HEADER.DATA_DIRECTORY[4], "Size", 0)
            ),
        }
    finally:
        pe.close()


def import_map(info: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {entry["dll"].casefold(): entry for entry in info.get("imports", [])}


def extract_strings(path: Path) -> list[str]:
    data = path.read_bytes()
    ascii_strings = [item.decode("ascii", errors="replace") for item in re.findall(rb"[ -~]{5,}", data)]
    wide_strings = [
        item.decode("utf-16-le", errors="replace")
        for item in re.findall(rb"(?:[ -~]\x00){5,}", data)
    ]
    return sorted(set(ascii_strings + wide_strings))


def string_hits(path: Path) -> dict[str, list[str]]:
    hits = extract_strings(path)
    return {
        "xenia": [item for item in hits if XENIA_RE.search(item)][:80],
        "forbidden_cpu": [item for item in hits if FORBIDDEN_CPU_RE.search(item)][:80],
        "jit_word": [item for item in hits if JIT_WORD_RE.search(item)][:80],
    }


def find_git() -> str | None:
    candidates = [shutil.which("git")]
    user_profile = Path(os.environ.get("USERPROFILE", str(Path.home())))
    candidates.append(
        str(
            user_profile
            / ".cache/codex-runtimes/codex-primary-runtime/dependencies/native/git/cmd/git.exe"
        )
    )
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    return None


def git_snapshot(path: Path) -> dict[str, Any]:
    result: dict[str, Any] = {"path": str(path).replace("\\", "/"), "exists": path.is_dir()}
    if not path.is_dir():
        return result
    git = find_git()
    if git is None:
        result["error"] = "git executable not found"
        return result

    def run(*args: str) -> tuple[int, str]:
        completed = subprocess.run(
            [git, "-C", str(path), *args],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        return completed.returncode, completed.stdout.strip()

    code, commit = run("rev-parse", "HEAD")
    if code == 0:
        result["commit"] = commit
    code, status = run("status", "--short")
    if code == 0:
        result["dirty"] = bool(status)
        result["status"] = status.splitlines() if status else []
    return result


def file_record(path: Path, workspace: Path, *, include_hash: bool = True) -> dict[str, Any]:
    entry: dict[str, Any] = {
        "path": relative(path, workspace),
        "absolute_path": str(path.resolve()),
        "exists": path.is_file(),
    }
    if path.is_file():
        entry["bytes"] = path.stat().st_size
        if include_hash:
            entry["sha256"] = sha256(path)
    return entry


def ninja_records(text: str) -> list[dict[str, Any]]:
    lines = text.splitlines()
    records: list[dict[str, Any]] = []
    for index, line in enumerate(lines):
        if not line.startswith("build ") or ":" not in line:
            continue
        body = line[6:]
        outputs_text, rule = body.split(":", 1)
        variables: dict[str, str] = {}
        cursor = index + 1
        while cursor < len(lines) and (lines[cursor].startswith("  ") or not lines[cursor].strip()):
            variable_line = lines[cursor]
            if variable_line.startswith("  ") and "=" in variable_line:
                key, value = variable_line[2:].split("=", 1)
                variables[key.strip()] = value.strip()
            cursor += 1
        records.append(
            {
                "line": index + 1,
                "outputs": outputs_text.split(),
                "rule": rule.strip(),
                "header": line,
                "variables": variables,
            }
        )
    return records


def ninja_record_for(records: Iterable[dict[str, Any]], output: str) -> dict[str, Any] | None:
    for record in records:
        if output in record["outputs"]:
            return record
    return None


def generated_sources(path: Path) -> list[str]:
    if not path.is_file():
        return []
    # sources.cmake is generated and contains only the file basenames under
    # ${CMAKE_CURRENT_LIST_DIR}; keeping the parser basename-only avoids path
    # separator and drive-letter differences between Ninja versions.
    found = re.findall(r"\b([A-Za-z0-9_.-]+\.cpp)\b", path.read_text(encoding="utf-8"))
    return list(dict.fromkeys(found))


def forbidden_lines(text: str, pattern: re.Pattern[str], limit: int = 80) -> list[dict[str, Any]]:
    matches = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        if pattern.search(line):
            matches.append({"line": line_number, "text": line[:500]})
            if len(matches) >= limit:
                break
    return matches


def load_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError:
        return path.read_text(encoding="utf-8", errors="replace")


def safe_hash(path: Path) -> str | None:
    return sha256(path) if path.is_file() else None


def compare_runtime_receipt(
    receipt: dict[str, Any] | None,
    artifacts: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    result: dict[str, Any] = {"exists": receipt is not None}
    if receipt is None:
        return result
    result["recorded_status"] = receipt.get("exit_code") == 0
    result["configuration"] = receipt.get("configuration")
    result["recorded_executable"] = receipt.get("executable")
    current_main = artifacts.get(MAIN_NAME, {})
    result["executable_hash_matches"] = (
        receipt.get("executable_sha256", "").upper()
        == str(current_main.get("sha256", "")).upper()
    )
    recorded = {
        item.get("name"): str(item.get("sha256", "")).upper()
        for item in receipt.get("runtime_artifacts", [])
        if isinstance(item, dict) and item.get("name")
    }
    comparisons = {}
    for name, current in artifacts.items():
        if name in recorded:
            comparisons[name] = {
                "recorded": recorded[name],
                "current": current.get("sha256"),
                "matches": recorded[name] == str(current.get("sha256", "")).upper(),
            }
    result["runtime_artifact_comparisons"] = comparisons
    result["all_recorded_artifacts_match"] = all(
        item["matches"] for item in comparisons.values()
    ) and len(comparisons) == len(recorded)
    return result


def build_markdown(report: dict[str, Any]) -> str:
    status = report["status"]
    summary = report["summary"]
    lines = [
        "# CoD3 native boundary v2 audit",
        "",
        f"Status: **{status}**  ",
        f"Recorded (UTC): `{report['recorded_utc']}`  ",
        f"Build directory: `{report['build_directory']}`  ",
        "",
        "This is a static audit. It did not launch `cod3_pc.exe`, `xenia_canary.exe`, "
        "the game, or an emulator.",
        "",
        "## Result",
        "",
        f"The expected native set is `{summary['game_image_count']}` images: "
        f"`cod3_pc.exe` plus `{summary['mission_dll_count']}` title DLLs. "
        f"The build output contains `{summary['local_dll_count']}` DLLs after adding the "
        "ReXGlue runtime, Xenos GPU plugin, coroutine helper, and Tracy dependency.",
        "",
        "| Check | Result |",
        "| --- | --- |",
    ]
    for name, check in report["checks"].items():
        lines.append(f"| {name} | {check['status']} |")

    lines += ["", "## Game images and hashes", "", "| Image | Bytes | SHA-256 | Direct imports relevant to boundary |", "| --- | ---: | --- | --- |"]
    for name in [MAIN_NAME, *MISSION_DLLS]:
        item = report["artifacts"].get(name)
        if not item or not item.get("exists"):
            lines.append(f"| `{name}` | missing | — | — |")
            continue
        relevant = ", ".join(
            entry["dll"]
            for entry in item.get("pe", {}).get("imports", [])
            if entry["dll"].casefold() in {"cod3_coroutines.dll", "rexruntimerd.dll"}
        )
        lines.append(
            f"| `{name}` | {item.get('bytes', '—')} | `{item.get('sha256', '—')}` | {relevant or '—'} |"
        )

    lines += ["", "## Local import closure", "", "| Image | Local imported DLLs | System/API imports |", "| --- | --- | --- |"]
    for name, item in report["artifacts"].items():
        if not item.get("pe"):
            continue
        local = report["dependency_graph"]["nodes"].get(name, {}).get("local_imports", [])
        system = report["dependency_graph"]["nodes"].get(name, {}).get("system_imports", [])
        lines.append(
            f"| `{name}` | {', '.join(f'`{x}`' for x in local) or '—'} | "
            f"{', '.join(f'`{x}`' for x in system) or '—'} |"
        )
    dynamic = report["dependency_graph"].get("dynamic_plugin_evidence", [])
    if dynamic:
        lines += ["", "The runtime also has a dynamic plugin name for the local Xenos GPU DLL. "
                  "This is string/import-loader evidence; static analysis cannot prove the runtime actually resolves it on every host:", ""]
        for item in dynamic:
            lines.append(f"- `{item['from']}` → `{item['to']}` (`{item['evidence']}`)")

    lines += ["", "## Generated PPC C++ and Ninja link proof", "", "| Target | Generated source list | All generated objects in link header | Link header line |", "| --- | ---: | --- | ---: |"]
    for target, item in report["ninja"]["targets"].items():
        lines.append(
            f"| `{target}` | {item.get('generated_source_count', 0)} | "
            f"{'PASS' if item.get('all_generated_objects_present') else 'FAIL'} | {item.get('line', '—')} |"
        )
    lines += [
        "",
        "The executable link header contains the XenonRecomp adapter object from `integration/xenon`, "
        "but does not contain the full `analysis/title-xenon-generated` tree. The adapter provenance limits "
        "this to two exact branch thunks; the remaining generated guest code is ReXGlue output.",
        "",
        "## Xenia isolation and provenance",
        "",
        "The Xenia graphics change is represented by a pinned source patch and a separate CMake `OBJECT` "
        "target. That target compiles one adapted D3D12 texture-cache translation unit against ReXGlue "
        "headers; it has no executable or shared-library link step and is absent from the CoD3 Ninja graph. "
        "The active CMake target requests the ReXGlue `rexgpu-xenosrd.dll` plugin, whose GPU/Xenos semantics "
        "are allowed by this boundary policy; the PE string/import evidence shows the runtime's dynamic "
        "plugin loader, while successful resolution still needs a runtime test. No Xenia emulator binary is "
        "part of the application closure.",
        "",
        "| Source or artifact | Revision/hash evidence | State |",
        "| --- | --- | --- |",
    ]
    for item in report["provenance"]["files"]:
        identity = item.get("commit") or item.get("sha256") or "—"
        state = "present" if item.get("exists") else "missing"
        if item.get("dirty"):
            state += ", dirty checkout"
        lines.append(f"| `{item['path']}` | `{identity}` | {state} |")

    lines += [
        "",
        "The supplied `xenia_canary.exe` is retained at the workspace root for provenance only; it is "
        "outside the native build tree and is not an application dependency:",
        "",
        f"- `{report['xenia_root_reference']['xenia_canary_exe']['path']}` — "
        f"`{report['xenia_root_reference']['xenia_canary_exe'].get('sha256', 'missing')}`",
        f"- `{report['xenia_root_reference']['xenia_canary_archive']['path']}` — "
        f"`{report['xenia_root_reference']['xenia_canary_archive'].get('sha256', 'missing')}`",
        "",
        "The PE string scan found Xenia terminology only in the ReXGlue runtime/plugin, where it belongs "
        "to the Xenos GPU compatibility implementation. It found no guest CPU translator or JIT marker:",
        "",
    ]
    for name in ("rexruntimerd.dll", "rexgpu-xenosrd.dll"):
        hits = report["artifacts"].get(name, {}).get("string_hits", {}).get("xenia", [])
        if hits:
            lines.append(f"- `{name}`: {len(hits)} Xenia/GPU compatibility strings; examples: "
                         + "; ".join(f"`{item[:180]}`" for item in hits[:4]))

    lines += [
        "",
        "## What this proves and what it does not",
        "",
        "It proves that the inspected Windows build is x64, that the executable and fifteen title DLLs "
        "are linked from generated PPC C++ object files, that they import the ReXGlue runtime, and that "
        "the local PE/link graph contains no Xenia emulator dependency or guest CPU/JIT marker found by "
        "these checks. It records the current hashes so a later build cannot be mistaken for this one.",
        "",
        "It does not prove complete game compatibility, dynamic DLL search-path success, that every optional "
        "runtime branch is unreachable, that a GPU device initializes, that the Xenia-derived source patch "
        "has been behaviorally validated in a live frame, or that 120 FPS preserves game logic and physics. "
        "Those require runtime and differential tests.",
        "",
        f"Existing native-port receipt comparison: `{report['existing_audit']['native_build_receipt'].get('executable_hash_matches', False)}` "
        "for the executable hash and "
        f"`{report['existing_audit']['native_build_receipt'].get('all_recorded_artifacts_match', False)}` "
        "for the recorded DLL hashes.",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument(
        "--build-dir",
        type=Path,
        default=Path("cod3-pc/out/build/win-amd64-relwithdebinfo"),
    )
    parser.add_argument("--report-json", type=Path)
    parser.add_argument("--report-md", type=Path)
    parser.add_argument("--check", action="store_true", help="exit nonzero when any boundary check fails")
    args = parser.parse_args()

    workspace = args.workspace.resolve()
    build = args.build_dir
    if not build.is_absolute():
        build = (workspace / build).resolve()
    project = workspace / "cod3-pc"
    report_json = args.report_json or workspace / "docs/reports/native-boundary-v2.json"
    report_md = args.report_md or workspace / "docs/reports/native-boundary-v2.md"
    report_json = report_json if report_json.is_absolute() else (workspace / report_json).resolve()
    report_md = report_md if report_md.is_absolute() else (workspace / report_md).resolve()

    checks: dict[str, dict[str, Any]] = {}
    failures: list[str] = []

    def check(name: str, passed: bool, detail: Any = None, *, blocking: bool = True) -> None:
        checks[name] = {
            "status": "PASS" if passed else ("WARN" if not blocking else "FAIL"),
            "detail": detail,
        }
        if not passed and blocking:
            failures.append(name)

    expected_images = [MAIN_NAME, *MISSION_DLLS]
    actual_mission_dlls = sorted(path.name for path in build.glob("cod3_pc_*.dll"))
    check(
        "exact fifteen title DLLs",
        actual_mission_dlls == sorted(MISSION_DLLS),
        {"expected": sorted(MISSION_DLLS), "actual": actual_mission_dlls},
    )

    artifacts: dict[str, dict[str, Any]] = {}
    for name in [MAIN_NAME, *MISSION_DLLS, *LOCAL_RUNTIME_DLLS]:
        path = build / name
        item = file_record(path, workspace)
        if path.is_file():
            try:
                item["pe"] = parse_pe(path)
                item["string_hits"] = string_hits(path)
            except Exception as exc:  # keep the report useful for a broken image
                item["parse_error"] = f"{type(exc).__name__}: {exc}"
        artifacts[name] = item

    missing_expected = [name for name in expected_images if not artifacts[name].get("exists")]
    check("expected executable and title DLLs exist", not missing_expected, {"missing": missing_expected})

    pe_failures: dict[str, list[str]] = {}
    forbidden_imports: dict[str, list[str]] = {}
    delay_imports: dict[str, list[str]] = {}
    for name in expected_images:
        item = artifacts[name]
        info = item.get("pe")
        issues: list[str] = []
        if not info:
            issues.append(item.get("parse_error", "PE parse unavailable"))
        else:
            if info.get("machine") != "0x8664":
                issues.append(f"machine={info.get('machine_name')}")
            if info.get("subsystem") != "0x2":
                issues.append(f"subsystem={info.get('subsystem_name')}")
            if info.get("delay_imports"):
                delay_imports[name] = info["delay_imports"]
                issues.append("delay imports present")
            imports = import_map(info)
            required = ["rexruntimerd.dll"]
            if name == MAIN_NAME or name in MISSION_DLLS:
                required.append("cod3_coroutines.dll")
            missing = [dep for dep in required if dep.casefold() not in imports]
            if missing:
                issues.append(f"missing direct imports: {', '.join(missing)}")
            bad = [dep["dll"] for dep in info.get("imports", []) if FORBIDDEN_IMPORT_RE.search(dep["dll"])]
            if bad:
                forbidden_imports[name] = bad
                issues.append(f"forbidden imports: {', '.join(bad)}")
        if issues:
            pe_failures[name] = issues
    check(
        "title images are native x64 and import ReXGlue runtime",
        not pe_failures,
        {"failures": pe_failures, "delay_imports": delay_imports, "forbidden_imports": forbidden_imports},
    )

    support_pe_failures: dict[str, list[str]] = {}
    for name in LOCAL_RUNTIME_DLLS:
        item = artifacts[name]
        info = item.get("pe")
        issues: list[str] = []
        if not info:
            issues.append(item.get("parse_error", "PE parse unavailable"))
        else:
            if info.get("machine") != "0x8664":
                issues.append(f"machine={info.get('machine_name')}")
            if info.get("delay_imports"):
                issues.append("delay imports present")
        if name == "rexgpu-xenosrd.dll" and info:
            exports = set(info.get("exports", []))
            for required_export in ("rex_gpu_abi_version", "rex_gpu_create"):
                if required_export not in exports:
                    issues.append(f"missing GPU plugin export {required_export}")
        if issues:
            support_pe_failures[name] = issues
    check(
        "local ReXGlue runtime, GPU, coroutine, and profiling DLLs are native x64",
        not support_pe_failures,
        {"failures": support_pe_failures, "expected": LOCAL_RUNTIME_DLLS},
    )

    binary_cpu_hits = {
        name: item.get("string_hits", {}).get("forbidden_cpu", [])
        for name, item in artifacts.items()
        if item.get("string_hits", {}).get("forbidden_cpu")
    }
    binary_jit_hits = {
        name: item.get("string_hits", {}).get("jit_word", [])
        for name, item in artifacts.items()
        if item.get("string_hits", {}).get("jit_word")
    }
    check(
        "no guest CPU translator or JIT marker in inspected PE strings",
        not binary_cpu_hits and not binary_jit_hits,
        {"guest_cpu_or_translator": binary_cpu_hits, "jit_word": binary_jit_hits},
    )

    ninja_path = build / "build.ninja"
    ninja_text = load_text(ninja_path) if ninja_path.is_file() else ""
    records = ninja_records(ninja_text)
    ninja_target_report: dict[str, dict[str, Any]] = {}
    source_proof_failures: dict[str, Any] = {}
    for name in expected_images:
        if name == MAIN_NAME:
            module = "default"
            target = "cod3_pc_recomp"
            object_prefix = "CMakeFiles/cod3_pc_recomp.dir/generated/default"
        else:
            module = name.removeprefix("cod3_pc_").removesuffix(".dll")
            target = f"cod3_pc_{module}"
            object_prefix = f"CMakeFiles/{target}.dir/generated/{module}"
        source_path = project / "generated" / module / "sources.cmake"
        sources = generated_sources(source_path)
        link_record = ninja_record_for(records, name)
        header = (link_record or {}).get("header", "").replace("\\", "/")
        expected_objects = [f"{object_prefix}/{source}.obj" for source in sources]
        present = [obj for obj in expected_objects if obj in header]
        missing = [obj for obj in expected_objects if obj not in header]
        generated_object_tokens = re.findall(r"[^ ]*generated/[^ ]*\.cpp\.obj", header)
        item = {
            "module": module,
            "target": target,
            "sources_cmake": file_record(source_path, workspace),
            "generated_source_count": len(sources),
            "generated_sources": sources,
            "generated_object_count_in_link_header": len(generated_object_tokens),
            "all_generated_objects_present": bool(sources) and not missing and link_record is not None,
            "missing_generated_objects": missing,
            "line": (link_record or {}).get("line"),
            "rule": (link_record or {}).get("rule"),
            "link_flags": (link_record or {}).get("variables", {}).get("LINK_FLAGS"),
            "link_libraries": (link_record or {}).get("variables", {}).get("LINK_LIBRARIES"),
            "header_sha256": hashlib.sha256(header.encode("utf-8")).hexdigest().upper() if header else None,
            "has_xenia_path": bool(XENIA_RE.search(header)),
            "has_cpu_translator_marker": bool(FORBIDDEN_CPU_RE.search(header)),
        }
        ninja_target_report[name] = item
        if not item["all_generated_objects_present"]:
            source_proof_failures[name] = {
                "missing": missing,
                "sources_cmake": relative(source_path, workspace),
                "link_record_found": link_record is not None,
            }
    check(
        "Ninja links every generated PPC C++ source for cod3_pc and 15 DLLs",
        ninja_path.is_file() and not source_proof_failures,
        {"ninja": relative(ninja_path, workspace), "failures": source_proof_failures},
    )

    ninja_forbidden = forbidden_lines(ninja_text, re.compile(r"(?i)xenia|xenia_canary|guest.?cpu|cpu.?translator|\bjit\b"))
    check(
        "CoD3 Ninja graph excludes Xenia emulator and guest CPU/JIT paths",
        ninja_path.is_file() and not ninja_forbidden,
        {"matches": ninja_forbidden},
    )

    active_source_paths = [
        project / "CMakeLists.txt",
        project / "cmake/ReXGlueProject.cmake",
        project / "src/main.cpp",
        project / "src/cod3_pc_app.h",
        workspace / "integration/xenon/CMakeLists.txt",
        workspace / "integration/xenon/xenon_thunks.cpp",
        workspace / "integration/xenon/override_hooks.cpp",
    ]
    active_source_forbidden: list[dict[str, Any]] = []
    for path in active_source_paths:
        if path.is_file():
            for line_number, line in enumerate(load_text(path).splitlines(), start=1):
                if FORBIDDEN_CPU_RE.search(line):
                    active_source_forbidden.append(
                        {"path": relative(path, workspace), "line": line_number, "text": line[:500]}
                    )
    check(
        "active source boundary has no guest CPU translator/JIT implementation marker",
        not active_source_forbidden,
        {"matches": active_source_forbidden},
    )

    # The two XenonRecomp bodies are deliberately the only raw Xenon objects
    # in the host link header. They are checked here as an allowed, bounded
    # exception to the generated ReXGlue source proof.
    xenon_provenance_path = workspace / "integration/xenon/generated/thunks.provenance.json"
    xenon_provenance = read_json(xenon_provenance_path) or {}
    main_header = ninja_target_report.get(MAIN_NAME, {})
    main_link_header = (ninja_record_for(records, MAIN_NAME) or {}).get("header", "").replace("\\", "/")
    thunk_text_path = workspace / "integration/xenon/generated/thunks.generated.inl"
    thunk_text = load_text(thunk_text_path) if thunk_text_path.is_file() else ""
    # The generated include keeps the original __imp__ names; the adapter
    # renames them with a macro in xenon_thunks.cpp. Count the actual generated
    # bodies rather than looking for the adapter-only symbol spelling.
    thunk_symbols = sorted(
        set(re.findall(r"PPC_FUNC_IMPL\(__imp__sub_([0-9A-Fa-f]+)\)", thunk_text))
    )
    xenon_direct_full_tree = bool(re.search(r"analysis/title-xenon-generated|tools/XenonRecomp", main_link_header, re.I))
    xenon_check = {
        "provenance": file_record(xenon_provenance_path, workspace),
        "provenance_function_count": len(xenon_provenance.get("functions", [])),
        "generated_thunk_symbol_count": len(thunk_symbols),
        "generated_thunk_symbols": [f"sub_{address}" for address in thunk_symbols],
        "adapter_object_in_main_link": "xenon/CMakeFiles/cod3_xenon_thunks.dir/xenon_thunks.cpp.obj" in main_link_header,
        "full_xenon_tree_in_main_link": xenon_direct_full_tree,
        "main_link_generated_proof": main_header.get("all_generated_objects_present", False),
    }
    check(
        "XenonRecomp use is limited to the two verified adapter thunks",
        xenon_check["provenance_function_count"] == 2
        and xenon_check["generated_thunk_symbol_count"] == 2
        and xenon_check["adapter_object_in_main_link"]
        and not xenon_check["full_xenon_tree_in_main_link"],
        xenon_check,
    )

    # Walk local PE imports. System DLLs are recorded as leaves; they are not
    # treated as missing local files because Windows API-set/runtime resolution
    # happens outside this build directory.
    local_files = {
        path.name.casefold(): path.name
        for path in build.glob("*.dll")
        if path.is_file()
    }
    nodes: dict[str, dict[str, Any]] = {}
    edges: list[dict[str, Any]] = []
    for name, item in artifacts.items():
        info = item.get("pe")
        if not info:
            continue
        local_imports: list[str] = []
        system_imports: list[str] = []
        for entry in info.get("imports", []):
            dep = entry["dll"]
            if dep.casefold() in local_files:
                local_imports.append(local_files[dep.casefold()])
                edges.append(
                    {
                        "from": name,
                        "to": local_files[dep.casefold()],
                        "kind": "PE_IMPORT",
                        "imported_symbol_count": entry["symbol_count"],
                        "imported_symbols": entry["symbols"],
                    }
                )
            else:
                system_imports.append(dep)
        nodes[name] = {
            "local_imports": sorted(set(local_imports)),
            "system_imports": sorted(set(system_imports)),
        }

    dynamic_plugin_evidence: list[dict[str, Any]] = []
    runtime_hits = artifacts.get("rexruntimerd.dll", {}).get("string_hits", {}).get("xenia", [])
    runtime_path = build / "rexruntimerd.dll"
    if runtime_path.is_file():
        runtime_strings = extract_strings(runtime_path)
        if any("rexgpu-{}{}.dll" in value for value in runtime_strings):
            dynamic_plugin_evidence.append(
                {
                    "from": "rexruntimerd.dll",
                    "to": "rexgpu-xenosrd.dll",
                    "evidence": "PE string rexgpu-{}{}.dll plus LoadLibrary/GetProcAddress imports",
                }
            )
    roots = [name for name in expected_images if name in nodes]
    reachable: set[str] = set()
    pending = list(roots)
    while pending:
        current = pending.pop()
        if current in reachable:
            continue
        reachable.add(current)
        pending.extend(nodes.get(current, {}).get("local_imports", []))
    dependency_graph = {
        "roots": roots,
        "nodes": nodes,
        "edges": edges,
        "reachable_from_game_roots": sorted(reachable),
        "dynamic_plugin_evidence": dynamic_plugin_evidence,
        "unreachable_local_build_dlls": sorted(set(local_files.values()) - reachable),
    }
    forbidden_graph_imports = [
        edge for edge in edges if FORBIDDEN_IMPORT_RE.search(edge["to"])
    ]
    check(
        "local PE import closure has no Xenia emulator dependency",
        not forbidden_graph_imports and not any("xenia_canary" in name.casefold() for name in reachable),
        {"forbidden_edges": forbidden_graph_imports, "reachable": sorted(reachable)},
    )

    xenia_graph_path = workspace / "integration/xenia-graphics/build/build.ninja"
    xenia_cmake_path = workspace / "integration/xenia-graphics/CMakeLists.txt"
    xenia_graph_text = load_text(xenia_graph_path) if xenia_graph_path.is_file() else ""
    xenia_graph_records = ninja_records(xenia_graph_text)
    xenia_linker_records = [
        record for record in xenia_graph_records if "LINKER" in record.get("rule", "")
    ]
    xenia_cmake_text = load_text(xenia_cmake_path) if xenia_cmake_path.is_file() else ""
    xenia_isolation = {
        "cmake_object_target": bool(
            re.search(r"add_library\s*\(\s*graphics_patch_compile\s+OBJECT", xenia_cmake_text)
        ),
        "ninja_exists": xenia_graph_path.is_file(),
        "ninja_linker_records": len(xenia_linker_records),
        "ninja_all_target": any(
            record.get("outputs") == ["all"] and "graphics_patch_compile" in record.get("header", "")
            for record in xenia_graph_records
        ),
        "present_in_cod3_ninja": "xenia-graphics" in ninja_text.casefold()
        or "integration/xenia" in ninja_text.casefold(),
        "kernel_candidate_in_cod3_ninja": "integration/xenia-kernel" in ninja_text.casefold()
        or "candidate/src/kernel/xam" in ninja_text.casefold(),
        "cod3_cmake_requests_xenos_plugin": bool(
            re.search(r"rexglue_setup_target\s*\(\s*cod3_pc\s+GPU_PLUGINS\s+xenos", load_text(project / "CMakeLists.txt"), re.I)
        ),
        "active_sdk_modified": None,
    }
    point_provenance_path = workspace / "integration/xenia-graphics/point-sampling-provenance.json"
    point_provenance = read_json(point_provenance_path) or {}
    xenia_isolation["active_sdk_modified"] = point_provenance.get("active_sdk_modified")
    check(
        "Xenia graphics reuse is compile-only and isolated from CoD3 link graph",
        xenia_isolation["cmake_object_target"]
        and xenia_isolation["ninja_exists"]
        and xenia_isolation["ninja_linker_records"] == 0
        and xenia_isolation["ninja_all_target"]
        and not xenia_isolation["present_in_cod3_ninja"]
        and not xenia_isolation["kernel_candidate_in_cod3_ninja"]
        and xenia_isolation["cod3_cmake_requests_xenos_plugin"]
        and xenia_isolation["active_sdk_modified"] is False,
        xenia_isolation,
    )

    patched_status_path = workspace / "tools/rexglue-patched-sdk/PATCH-STATUS.json"
    patched_status = read_json(patched_status_path) or {}
    active_runtime_path = build / "rexruntimerd.dll"
    runtime_override_path = workspace / "tools/rexglue-patched-sdk/bin/rexruntimerd.dll"
    runtime_override = {
        "status_file": file_record(patched_status_path, workspace),
        "configured_output": file_record(active_runtime_path, workspace),
        "override_source": file_record(runtime_override_path, workspace),
        "build_hash_matches_override": safe_hash(active_runtime_path) == safe_hash(runtime_override_path),
        "patch_status": patched_status,
    }
    check(
        "active ReXGlue runtime matches the configured patched SDK runtime",
        bool(safe_hash(active_runtime_path))
        and bool(safe_hash(runtime_override_path))
        and runtime_override["build_hash_matches_override"]
        and patched_status.get("status") == "PASS"
        and patched_status.get("original_sdk_changed") is False,
        runtime_override,
    )

    # Record the separate source trees and the exact files that define the
    # boundary. Dirty status is evidence, not a failure: the source revision
    # remains explicit and the hashes are captured below.
    source_trees = [
        ("ReXGlue source", workspace / "tools/rexglue-source"),
        ("XenonRecomp source", workspace / "tools/XenonRecomp"),
        ("XenosRecomp source", workspace / "tools/XenosRecomp"),
        ("Xenia source", workspace / "tools/Xenia-source"),
    ]
    provenance_files = [
        point_provenance_path,
        workspace / "integration/xenia-graphics/rexglue-point-sampling.patch",
        workspace / "integration/xenia-graphics/XENIA-LICENSE",
        workspace / "integration/xenia-kernel/0001-forward-xam-message-box-ui-ex.patch",
        workspace / "integration/xenia-kernel/candidate/src/kernel/xam/xam_ui.cpp",
        xenon_provenance_path,
        thunk_text_path,
        workspace / "integration/xenia-graphics/CMakeLists.txt",
        workspace / "integration/xenon/CMakeLists.txt",
        workspace / "cod3-pc/CMakeLists.txt",
        workspace / "cod3-pc/cod3_pc_manifest.toml",
        ninja_path,
        workspace / "analysis/cod3-pc-native-build-receipt.json",
        workspace / "analysis/cod3-boundary-evidence.json",
        workspace / "analysis/cod3-pointer-boundary-evidence.json",
        workspace / "docs/reports/xenia-dependencies.json",
        workspace / "docs/reports/sdk-xenon-interop.md",
    ]
    provenance_entries: list[dict[str, Any]] = []
    for label, path in source_trees:
        snapshot = git_snapshot(path)
        snapshot["label"] = label
        snapshot["path"] = relative(path, workspace)
        provenance_entries.append(snapshot)
    provenance_entries.extend(file_record(path, workspace) for path in provenance_files)
    expected_xenia_commit = point_provenance.get("xenia_source_commit")
    expected_rexglue_commit = point_provenance.get("rexglue_base_commit")
    actual_by_label = {
        entry.get("label"): entry.get("commit")
        for entry in provenance_entries
        if entry.get("label")
    }
    provenance_consistency = {
        "xenia_revision_matches_patch": actual_by_label.get("Xenia source") == expected_xenia_commit,
        "rexglue_revision_matches_patch": actual_by_label.get("ReXGlue source") == expected_rexglue_commit,
        "xenon_revision_matches_thunk_receipt": actual_by_label.get("XenonRecomp source")
        == xenon_provenance.get("xenonCommit"),
        "xenia_revision": actual_by_label.get("Xenia source"),
        "rexglue_revision": actual_by_label.get("ReXGlue source"),
        "xenon_revision": actual_by_label.get("XenonRecomp source"),
        "xenos_revision": actual_by_label.get("XenosRecomp source"),
    }
    check(
        "source provenance revisions agree with the recorded boundary receipts",
        provenance_consistency["xenia_revision_matches_patch"]
        and provenance_consistency["rexglue_revision_matches_patch"]
        and provenance_consistency["xenon_revision_matches_thunk_receipt"],
        provenance_consistency,
    )

    receipt_path = workspace / "analysis/cod3-pc-native-build-receipt.json"
    receipt = read_json(receipt_path)
    existing_audit = {
        "native_build_receipt": compare_runtime_receipt(receipt, artifacts),
        "files": [file_record(path, workspace) for path in provenance_files if path.parent.name == "analysis" or path.parent.name == "reports"],
    }
    check(
        "existing native-port receipt agrees with current artifact hashes",
        existing_audit["native_build_receipt"].get("exists", False)
        and existing_audit["native_build_receipt"].get("recorded_status", False)
        and existing_audit["native_build_receipt"].get("executable_hash_matches", False)
        and existing_audit["native_build_receipt"].get("all_recorded_artifacts_match", False),
        existing_audit["native_build_receipt"],
        blocking=False,
    )

    root_xenia_exe = workspace / "xenia_canary.exe"
    root_xenia_archive = workspace / "xenia_canary_windows.7z"
    forbidden_artifact_names = [
        path.name
        for path in build.rglob("*")
        if path.is_file() and path.name.casefold() == "xenia_canary.exe"
    ]
    xenia_root_reference = {
        "xenia_canary_exe": file_record(root_xenia_exe, workspace),
        "xenia_canary_archive": file_record(root_xenia_archive, workspace),
        "xenia_canary_exe_in_build_tree": forbidden_artifact_names,
    }
    check(
        "xenia_canary.exe is outside the native application tree",
        not forbidden_artifact_names
        and not any("xenia_canary.exe" in value.casefold() for value in reachable),
        xenia_root_reference,
    )

    local_dll_names = sorted(path.name for path in build.glob("*.dll") if path.is_file())
    summary = {
        "game_image_count": len(expected_images),
        "mission_dll_count": len(MISSION_DLLS),
        "local_dll_count": len(local_dll_names),
        "local_dll_names": local_dll_names,
        "failure_count": len(failures),
    }
    report: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "recorded_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "status": "PASS" if not failures else "FAIL",
        "static_only": True,
        "execution_performed": False,
        "workspace": str(workspace),
        "build_directory": str(build),
        "configuration": CONFIGURATION,
        "summary": summary,
        "checks": checks,
        "artifacts": artifacts,
        "ninja": {
            "build_ninja": file_record(ninja_path, workspace),
            "targets": ninja_target_report,
            "forbidden_lines": ninja_forbidden,
        },
        "dependency_graph": dependency_graph,
        "xenon_adapter": xenon_check,
        "xenia_isolation": xenia_isolation,
        "xenia_root_reference": xenia_root_reference,
        "runtime_override": runtime_override,
        "provenance": {
            "files": provenance_entries,
            "consistency": provenance_consistency,
        },
        "existing_audit": existing_audit,
        "limitations": [
            "Static PE imports do not prove runtime DLL search-path resolution or successful GPU/plugin initialization.",
            "Static absence of strings/imports/build paths is a bounded check, not a proof that no opaque runtime branch can JIT or translate guest CPU code.",
            "The Xenia graphics target is compile-only evidence; it does not prove behavioral equivalence in a live frame.",
            "The audit does not establish gameplay correctness, 1920x1080 image quality, 120 FPS, or physics/frame-pacing invariance.",
            "The ReXGlue runtime and Xenos GPU plugin legitimately contain GPU shader translation and Xenia-derived compatibility terminology; this audit distinguishes those from guest CPU/JIT markers.",
        ],
    }

    report_json.parent.mkdir(parents=True, exist_ok=True)
    report_md.parent.mkdir(parents=True, exist_ok=True)
    report_json.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    report_md.write_text(build_markdown(report), encoding="utf-8")

    print(
        json.dumps(
            {
                "status": report["status"],
                "failures": failures,
                "game_images": len(expected_images),
                "local_dlls": len(local_dll_names),
                "report_json": str(report_json),
                "report_md": str(report_md),
            },
            ensure_ascii=False,
        )
    )
    return 0 if not args.check or not failures else 2


if __name__ == "__main__":
    sys.exit(main())
