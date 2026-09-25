#!/usr/bin/env python3
"""Stage a pinned Xenia D3D12 sampling fix against the matching ReXGlue source.

The original SDK/source checkout is not modified. The generated patch and
two-file overlay are ready for the runtime build owner to review and apply.
"""

from __future__ import annotations

import difflib
import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parents[2]
ROOT = Path(__file__).resolve().parent
REX = WORKSPACE / "tools/rexglue-source"
XENIA = WORKSPACE / "tools/Xenia-source"
GIT = Path.home() / ".cache/codex-runtimes/codex-primary-runtime/dependencies/native/git/cmd/git.exe"
REX_SHA = "0c7b01a0ac0479801757507d80533f662fa0815d"
XENIA_SHA = "0e1307bd2e6bfeeff29635a6b823e72e61c97ce9"
UPSTREAM_FIX = "197929d967f587502256fd52c0c5121781fd0e47"

# Keep the provenance visible in every generated source file. The BSD-3-Clause
# text is copied to XENIA-LICENSE alongside the overlay and the complete
# upstream commit is retained in upstream-197929d.patch.
ATTRIBUTION = (
    " * @upstream   Xenia Canary commit " + UPSTREAM_FIX + "\n"
    " * @adaptation D3D12 point-sampling fallback only; no Xenia renderer or JIT\n"
)


def git(*args: str) -> str:
    return subprocess.check_output([str(GIT), *args], text=True, encoding="utf-8")


def once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError(f"expected one exact source anchor, found {text.count(old)}: {old[:80]}")
    return text.replace(old, new, 1)


def main() -> None:
    if git("-C", str(REX), "rev-parse", "HEAD").strip() != REX_SHA:
        raise ValueError("ReXGlue source is not the verified SDK revision")
    if git("-C", str(XENIA), "rev-parse", "HEAD").strip() != XENIA_SHA:
        raise ValueError("Xenia source is not the revision of the supplied executable")
    cpp_path = "src/graphics/d3d12/texture_cache.cpp"
    header_path = "include/rex/graphics/d3d12/texture_cache.h"
    sources = {path: (REX / path).read_text(encoding="utf-8") for path in (cpp_path, header_path)}
    source = sources[cpp_path]
    upstream = (XENIA / "src/xenia/gpu/d3d12/d3d12_texture_cache.cc").read_text(encoding="utf-8")
    capability_start = upstream.index("  // GetSamplerParameters drops samplers for non-filterable formats.")
    capability_end = upstream.index("  // Create the loading root signature.", capability_start)
    capabilities = upstream[capability_start:capability_end].replace("xe::countof", "rex::countof")
    fallback_start = upstream.index("  // Fall back to point sampling if the host formats don't report")
    fallback_end = upstream.index("  return parameters;", fallback_start)
    fallback = upstream[fallback_start:fallback_end]
    source = once(source, "  // Create the loading root signature.\n", capabilities + "  // Create the loading root signature.\n")
    source = once(source, "  // TODO(Triang3l): Disable filtering for texture formats not supporting it.\n", "")
    source = once(source, "  parameters.mip_base_map = mip_base_map;\n\n  return parameters;", "  parameters.mip_base_map = mip_base_map;\n\n" + fallback + "  return parameters;")
    header = once(sources[header_path], "  bool bindless_resources_used_;\n\n", "  bool bindless_resources_used_;\n\n  // Bits per format, for checking if the host format should be point-filtered.\n  uint64_t host_filterable_unsigned_ = 0;\n  uint64_t host_filterable_signed_ = 0;\n\n")
    source = once(source, " * @modified    Tom Clay, 2026 - Adapted for ReXGlue runtime\n", " * @modified    Tom Clay, 2026 - Adapted for ReXGlue runtime\n" + ATTRIBUTION)
    header = once(header, " * @modified    Tom Clay, 2026 - Adapted for ReXGlue runtime\n", " * @modified    Tom Clay, 2026 - Adapted for ReXGlue runtime\n" + ATTRIBUTION)
    revised = {cpp_path: source, header_path: header}
    provenance = {"schema_version": 1, "created_utc": datetime.now(timezone.utc).isoformat(), "rexglue_base_commit": REX_SHA, "xenia_source_commit": XENIA_SHA, "upstream_fix_commit": UPSTREAM_FIX, "upstream_fix_url": f"https://github.com/xenia-canary/xenia-canary/commit/{UPSTREAM_FIX}", "active_sdk_modified": False, "game_launch_performed": False, "files": []}
    patch = []
    for path, text in revised.items():
        output = ROOT / "overlay" / path
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(text, encoding="utf-8", newline="\n")
        source_bytes = (REX / path).read_bytes()
        output_bytes = output.read_bytes()
        provenance["files"].append({"path": path, "base_file_sha256": hashlib.sha256(source_bytes).hexdigest(), "overlay_file_sha256": hashlib.sha256(output_bytes).hexdigest()})
        patch.extend(difflib.unified_diff(sources[path].splitlines(keepends=True), text.splitlines(keepends=True), fromfile=f"a/{path}", tofile=f"b/{path}"))
    patch_path = ROOT / "rexglue-point-sampling.patch"
    patch_path.write_text("".join(patch), encoding="utf-8", newline="\n")
    provenance["patch_sha256"] = hashlib.sha256(patch_path.read_bytes()).hexdigest()
    (ROOT / "XENIA-LICENSE").write_bytes((XENIA / "LICENSE").read_bytes())
    (ROOT / "upstream-197929d.patch").write_text(git("-C", str(XENIA), "show", "--format=fuller", UPSTREAM_FIX), encoding="utf-8", newline="\n")
    (ROOT / "point-sampling-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"patch": str(patch_path), "file_count": len(revised), "patch_sha256": provenance["patch_sha256"]}))


if __name__ == "__main__":
    main()
