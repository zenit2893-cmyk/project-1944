"""Prepare an isolated spatial-only ReXGlue presenter patch and exact-source probe."""
from __future__ import annotations
import difflib
import hashlib
import json
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SOURCE = ROOT / "tools/rexglue-source"
XENIA_SOURCE = ROOT / "tools/Xenia-source"
OVERLAY = HERE / "overlay"


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError(f"Expected one source anchor, got {text.count(old)}: {old[:100]}")
    return text.replace(old, new, 1)


def git_head(repository: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(repository), "rev-parse", "HEAD"], text=True
    ).strip()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


paths = [
    "include/rex/ui/presenter.h", "include/rex/ui/d3d12/d3d12_presenter.h",
    "include/rex/ui/vulkan/presenter.h", "src/ui/presenter.cpp",
    "src/ui/d3d12/d3d12_presenter.cpp", "src/ui/vulkan/vulkan_presenter.cpp",
    "src/ui/CMakeLists.txt", "src/system/CMakeLists.txt",
]
original = {name: (SOURCE / name).read_text(encoding="utf-8-sig") for name in paths}
changed = dict(original)
for name in paths[:6]:
    # The SDK's existing guard also covers the optional temporal FFX runtime.
    # Keep the checked-in FSR1/CAS shader path independently selectable, and
    # make the value part of the gate so an explicit ``=0`` cannot accidentally
    # expose the spatial enum or shader tables.
    changed[name] = changed[name].replace(
        "#if defined(REX_HAS_FIDELITYFX_SDK)",
        "#if defined(REX_HAS_FIDELITYFX_SPATIAL) && REX_HAS_FIDELITYFX_SPATIAL",
    ).replace(
        "#endif  // defined(REX_HAS_FIDELITYFX_SDK)",
        "#endif  // defined(REX_HAS_FIDELITYFX_SPATIAL) && REX_HAS_FIDELITYFX_SPATIAL",
    )

name = "src/ui/presenter.cpp"
text = changed[name]
old = '''REXCVAR_DEFINE_STRING(present_effect, "bilinear", "UI/Presenter",
                      "Guest output effect: bilinear, cas, fsr, fsr2, fsr3")
    .allowed({"bilinear", "cas", "fsr", "fsr2", "fsr3"})
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);'''
new = '''#if defined(REX_HAS_FIDELITYFX_RUNTIME) && REX_HAS_FIDELITYFX_RUNTIME
''' + old + '''
#else
REXCVAR_DEFINE_STRING(present_effect, "bilinear", "UI/Presenter",
                      "Guest output spatial effect: bilinear, cas, fsr")
    .allowed({"bilinear", "cas", "fsr"})
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);
#endif'''
text = replace_once(text, old, new)
quality_definition = '''REXCVAR_DEFINE_STRING(
    present_fsr_quality_mode, "auto", "UI/Presenter",
    "Temporal FSR quality mode: auto, nativeaa, quality, balanced, performance, ultra_performance")
    .allowed({"auto", "nativeaa", "quality", "balanced", "performance", "ultra_performance"})
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);'''
text = replace_once(text, quality_definition,
                    "#if defined(REX_HAS_FIDELITYFX_RUNTIME) && REX_HAS_FIDELITYFX_RUNTIME\n" + quality_definition + "\n#endif")
temporal_parse = '''  if (lowered == "fsr2") {
    return GuestOutputPaintConfig::Effect::kFsr2;
  }
  if (lowered == "fsr3") {
    return GuestOutputPaintConfig::Effect::kFsr3;
  }'''
text = replace_once(text, temporal_parse,
                    "#if defined(REX_HAS_FIDELITYFX_RUNTIME) && REX_HAS_FIDELITYFX_RUNTIME\n" + temporal_parse + "\n#endif")
quality_setter = "  config.SetFsrQualityMode(ParsePresentFsrQualityMode(REXCVAR_GET(present_fsr_quality_mode)));"
text = replace_once(text, quality_setter,
                    "#if defined(REX_HAS_FIDELITYFX_RUNTIME) && REX_HAS_FIDELITYFX_RUNTIME\n" + quality_setter + "\n#endif")
changed[name] = text

spatial_condition = '''if(REXGLUE_ENABLE_SPATIAL_UPSCALING OR
   (REXGLUE_FIDELITYFX_SOURCE_DIR AND EXISTS "${REXGLUE_FIDELITYFX_SOURCE_DIR}/sdk/include"))
'''
changed["src/ui/CMakeLists.txt"] = replace_once(
    changed["src/ui/CMakeLists.txt"], "# rexui\n",
    '''# rexui

# The checked-in CAS/FSR1 shaders and CPU constants do not need the AMD runtime SDK.
option(REXGLUE_ENABLE_SPATIAL_UPSCALING "Enable precompiled CAS/FSR1 presentation shaders" OFF)
''')
changed["src/ui/CMakeLists.txt"] = replace_once(
    changed["src/ui/CMakeLists.txt"], "set(REXUI_HAS_FIDELITYFX_RUNTIME OFF)",
    spatial_condition + '''    target_compile_definitions(rexui PUBLIC REX_HAS_FIDELITYFX_SPATIAL=1)
endif()

set(REXUI_HAS_FIDELITYFX_RUNTIME OFF)''')
system = changed["src/system/CMakeLists.txt"]
system = replace_once(system, "add_library(rexruntime SHARED ${REXSYSTEM_SOURCES})",
    '''add_library(rexruntime SHARED ${REXSYSTEM_SOURCES})

# rexruntime links rexui privately, so publish the presenter layout capability
# explicitly for applications and GPU plugins consuming the installed runtime.
''' + spatial_condition + '''    target_compile_definitions(rexruntime PUBLIC REX_HAS_FIDELITYFX_SPATIAL=1)
endif()''')
changed["src/system/CMakeLists.txt"] = system

rexglue_commit = git_head(SOURCE)
xenia_commit = git_head(XENIA_SOURCE)
xenia_source_files = [
    "src/xenia/ui/presenter.h",
    "src/xenia/ui/presenter.cc",
    "src/xenia/ui/d3d12/d3d12_presenter.h",
    "src/xenia/ui/d3d12/d3d12_presenter.cc",
    "src/xenia/ui/shaders/guest_output_ffx_fsr_easu.ps.xesl",
    "src/xenia/ui/shaders/guest_output_ffx_fsr_rcas.xesli",
    "src/xenia/ui/shaders/guest_output_ffx_fsr_rcas.ps.xesl",
    "src/xenia/ui/shaders/guest_output_ffx_cas_resample.xesli",
    "src/xenia/ui/shaders/guest_output_ffx_cas_resample.ps.xesl",
]
spatial_shader_files = [
    "src/ui/shaders/bytecode/d3d12_5_1/guest_output_ffx_cas_resample_dither_ps.h",
    "src/ui/shaders/bytecode/d3d12_5_1/guest_output_ffx_cas_resample_ps.h",
    "src/ui/shaders/bytecode/d3d12_5_1/guest_output_ffx_cas_sharpen_dither_ps.h",
    "src/ui/shaders/bytecode/d3d12_5_1/guest_output_ffx_cas_sharpen_ps.h",
    "src/ui/shaders/bytecode/d3d12_5_1/guest_output_ffx_fsr_easu_ps.h",
    "src/ui/shaders/bytecode/d3d12_5_1/guest_output_ffx_fsr_rcas_dither_ps.h",
    "src/ui/shaders/bytecode/d3d12_5_1/guest_output_ffx_fsr_rcas_ps.h",
]
manifest = {
    "source_commit": rexglue_commit,
    "xenia_source_commit": xenia_commit,
    "xenia_license": {
        "path": "tools/Xenia-source/LICENSE",
        "sha256": sha256(XENIA_SOURCE / "LICENSE"),
        "spdx": "BSD-3-Clause",
    },
    "xenia_presenter_sources": [
        {"path": path, "sha256": sha256(XENIA_SOURCE / path)}
        for path in xenia_source_files
    ],
    "spatial_shader_blobs": [
        {"path": path, "sha256": sha256(SOURCE / path)}
        for path in spatial_shader_files
    ],
    "spatial_option": "REXGLUE_ENABLE_SPATIAL_UPSCALING=ON",
    "spatial_compile_define": "REX_HAS_FIDELITYFX_SPATIAL=1",
    "temporal_option": "REXGLUE_ENABLE_FIDELITYFX=OFF",
    "temporal_compile_define": "REX_HAS_FIDELITYFX_RUNTIME absent",
    "guest_timing_unchanged": True,
    "guest_video_mode_unchanged": True,
    "active_sdk_modified": False,
    "files": [],
}
patch = []
for name in paths:
    destination = OVERLAY / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(changed[name], encoding="utf-8", newline="\n")
    patch.extend(difflib.unified_diff(original[name].splitlines(True), changed[name].splitlines(True),
                                    fromfile="a/" + name, tofile="b/" + name))
    manifest["files"].append({"path": name,
                              "source_sha256": hashlib.sha256((SOURCE / name).read_bytes()).hexdigest(),
                              "overlay_sha256": hashlib.sha256(destination.read_bytes()).hexdigest()})
(HERE / "rexglue-spatial.patch").write_text("".join(patch), encoding="utf-8", newline="\n")
(HERE / "overlay-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def extract_function(source: str, marker: str) -> str:
    start = source.index(marker)
    end = source.index("\n}\n", start) + 3
    return source[start:end]


parser = extract_function(text, "GuestOutputPaintConfig::Effect ParsePresentEffect(")
flow = extract_function(text, "Presenter::GuestOutputPaintFlow Presenter::GetGuestOutputPaintFlow(")
flow = replace_once(flow, "Presenter::GuestOutputPaintFlow Presenter::GetGuestOutputPaintFlow(",
                    "GuestOutputPaintFlow BuildFlow(")
flow = replace_once(flow, "const GuestOutputPaintConfig& config) const {",
                    "const GuestOutputPaintConfig& config, uint32_t surface_width_in_paint_connection_,\n"
                    "    uint32_t surface_height_in_paint_connection_) {")
generated = "// Exact source bodies from the isolated presenter overlay; only the method wrapper\n" \
            "// is adapted to provide surface dimensions without constructing a window or GPU.\n" \
            + parser + "\n\n" + flow
(HERE / "flow_under_test.inc").write_text(generated, encoding="utf-8", newline="\n")
print(f"Prepared {len(paths)} source overlays and a patch; no active SDK/build files changed.")
