#!/usr/bin/env python3
"""Validate the isolated Xenia D3D12 sampling overlay.

This is a read-only artifact test. It checks the pinned source revisions,
generated overlay hashes, upstream license/notice, and the narrow patch shape;
it does not configure a runtime, create a D3D12 device, or launch the game.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
INTEGRATION = ROOT / "integration" / "xenia-graphics"
REX = ROOT / "tools" / "rexglue-source"
XENIA = ROOT / "tools" / "Xenia-source"
PROVENANCE_PATH = INTEGRATION / "point-sampling-provenance.json"
PATCH_PATH = INTEGRATION / "rexglue-point-sampling.patch"
LICENSE_PATH = INTEGRATION / "XENIA-LICENSE"
UPSTREAM_PATCH_PATH = INTEGRATION / "upstream-197929d.patch"

REX_SHA = "0c7b01a0ac0479801757507d80533f662fa0815d"
XENIA_SHA = "0e1307bd2e6bfeeff29635a6b823e72e61c97ce9"
UPSTREAM_FIX = "197929d967f587502256fd52c0c5121781fd0e47"
PATCH_FILES = {
    "src/graphics/d3d12/texture_cache.cpp",
    "include/rex/graphics/d3d12/texture_cache.h",
}


def git_executable() -> str:
    bundled = (
        Path.home()
        / ".cache"
        / "codex-runtimes"
        / "codex-primary-runtime"
        / "dependencies"
        / "native"
        / "git"
        / "cmd"
        / "git.exe"
    )
    if bundled.exists():
        return str(bundled)
    found = shutil.which("git")
    if found:
        return found
    raise RuntimeError("git executable is required for source pin validation")


def git(*args: str) -> str:
    return subprocess.check_output(
        [git_executable(), *args],
        text=True,
        encoding="utf-8",
    ).strip()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    provenance = json.loads(PROVENANCE_PATH.read_text(encoding="utf-8"))
    require(provenance["rexglue_base_commit"] == REX_SHA, "ReXGlue provenance pin changed")
    require(provenance["xenia_source_commit"] == XENIA_SHA, "Xenia provenance pin changed")
    require(provenance["upstream_fix_commit"] == UPSTREAM_FIX, "upstream fix pin changed")
    require(provenance["active_sdk_modified"] is False, "active SDK must remain untouched")
    require(provenance["game_launch_performed"] is False, "artifact test must not launch the game")

    require(git("-C", str(REX), "rev-parse", "HEAD") == REX_SHA, "ReXGlue checkout is not pinned")
    require(git("-C", str(XENIA), "rev-parse", "HEAD") == XENIA_SHA, "Xenia checkout is not pinned")

    upstream_names = set(
        git("-C", str(XENIA), "show", "--format=", "--name-only", UPSTREAM_FIX).splitlines()
    )
    require(
        "src/xenia/gpu/d3d12/d3d12_texture_cache.cc" in upstream_names,
        "upstream change must touch the Xenia D3D12 texture cache",
    )
    require(
        "src/xenia/gpu/d3d12/d3d12_texture_cache.h" in upstream_names,
        "upstream change must touch the Xenia D3D12 texture cache header",
    )

    recorded_files = {entry["path"]: entry for entry in provenance["files"]}
    require(set(recorded_files) == PATCH_FILES, "overlay must contain exactly two source files")
    for relative in sorted(PATCH_FILES):
        base = REX / relative
        overlay = INTEGRATION / "overlay" / relative
        entry = recorded_files[relative]
        require(sha256(base) == entry["base_file_sha256"], f"base hash drifted: {relative}")
        require(sha256(overlay) == entry["overlay_file_sha256"], f"overlay hash drifted: {relative}")

    patch = PATCH_PATH.read_text(encoding="utf-8")
    require(
        patch.count("--- a/src/graphics/d3d12/texture_cache.cpp") == 1,
        "texture cache source must have one patch section",
    )
    require(
        patch.count("--- a/include/rex/graphics/d3d12/texture_cache.h") == 1,
        "texture cache header must have one patch section",
    )
    require("D3D12_FEATURE_DATA_FORMAT_SUPPORT" in patch, "D3D12 format capability query missing")
    require("D3D12_FORMAT_SUPPORT1_SHADER_SAMPLE" in patch, "shader sample capability check missing")
    require("host_filterable_unsigned_" in patch, "unsigned filterability mask missing")
    require("host_filterable_signed_" in patch, "signed filterability mask missing")
    require("parameters.aniso_filter = xenos::AnisoFilter::kDisabled;" in patch, "aniso fallback missing")
    require("no Xenia renderer or JIT" in patch, "scope boundary attribution missing")
    patch_headers = {
        line[6:]
        for line in patch.splitlines()
        if line.startswith("--- a/")
    }
    require(patch_headers == PATCH_FILES, "patch contains an out-of-scope file")
    require(sha256(PATCH_PATH) == provenance["patch_sha256"], "patch hash drifted")

    require(LICENSE_PATH.read_bytes() == (XENIA / "LICENSE").read_bytes(), "Xenia license not preserved")
    upstream_notice = UPSTREAM_PATCH_PATH.read_text(encoding="utf-8")
    require(UPSTREAM_FIX in upstream_notice, "upstream commit id missing from retained notice")
    require("Fall back to point sampling" in upstream_notice, "upstream fallback notice missing")

    print("xenia-d3d12-point-sampling: PASS")
    print(f"  source pins: rexglue={REX_SHA}, xenia={XENIA_SHA}")
    print(f"  overlay files: {len(PATCH_FILES)}; patch sha256={provenance['patch_sha256']}")


if __name__ == "__main__":
    main()
