# COD3 native build integration audit

This report covers the build-system handoff for the active `cod3-pc` project.
It does not launch the game, an emulator, or a GUI. The active
`cod3-pc/CMakeLists.txt` was left unchanged; the reusable contract lives in
`integration/build-system/Cod3NativeBuildIntegration.cmake` and can be included
after the generated ReXGlue target and the native integration subdirectories
have been declared.

## Findings from the current generated build

The existing project has the expected native shape:

- `generated/rexglue.cmake` remains the SDK generated file and contains the
  stock direct codegen command.
- The configure adapter writes `rexglue-project.cmake` in the build directory
  and replaces that command with `cmake/Invoke-Codegen.ps1`. The helper runs one
  fresh ReXGlue process per mission overlay and reconstructs the complete
  registry after all 15 passes.
- `generated/default/dll_targets.cmake` declares these 15 shared targets:
  `blkbrn`, `chambois`, `credits`, `crssrds`, `falaise`, `forest`, `fuelplnt`,
  `hostage`, `island`, `laison`, `mace2`, `mayenne`, `nightd`, `saint_lo`, and
  `stbert`. `module_registry.cpp` contains the matching full guest paths.
- The active graph contains the coroutine bridge, Xenon thunk object, timing
  observer, timing hook object, and the Xenos GPU plugin. The upscaling project
  under `integration/upscaling` is a compile/probe target and is not a live
  host dependency.

The isolated configure probe also exposed a real configuration problem. When
`COD3_RUNTIME_DLL` points at the patched
`tools/rexglue-patched-sdk/bin/rexruntimerd.dll`, the current top-level CMake
changes only `IMPORTED_LOCATION_RELWITHDEBINFO` on `rex::runtime`. Its generated
link lines still use the original
`win-amd64/lib/rexruntimerd.lib`, while the post-build output contains the
patched DLL. A DLL/import-library pair from different runtime builds can hide
ABI and export differences until process startup.

The new contract sets both `IMPORTED_LOCATION_RELWITHDEBINFO` and
`IMPORTED_IMPLIB_RELWITHDEBINFO` to the selected patched pair, verifies the
configuration-specific file names, and stages the selected DLL and matching
PDB beside the host. It also stages the selected `rexgpu-xenos` binary through
`TARGET_FILE`, so a RelWithDebInfo host cannot accidentally receive the Debug
or Release plugin.

## Integration include

Add the include in the top-level `cod3-pc` directory after
`rexglue_setup_target(cod3_pc GPU_PLUGINS xenos)`, the Xenon/coroutine/timing
subdirectories, and any optional diagnostics have been added:

```cmake
include("${CMAKE_CURRENT_SOURCE_DIR}/../integration/build-system/Cod3NativeBuildIntegration.cmake")

if(COD3_RUNTIME_DLL)
    cod3_native_integrate(
        HOST_TARGET cod3_pc
        ENTRYPOINT_OBJECT_TARGET cod3_pc_recomp
        CODEGEN_TARGET cod3_pc_codegen
        RUNTIME_CONFIGURATION RelWithDebInfo
        RUNTIME_DLL "${COD3_RUNTIME_DLL}"
        REQUIRE_PATCHED_RUNTIME)
else()
    cod3_native_integrate(
        HOST_TARGET cod3_pc
        ENTRYPOINT_OBJECT_TARGET cod3_pc_recomp
        CODEGEN_TARGET cod3_pc_codegen
        RUNTIME_CONFIGURATION "${CMAKE_BUILD_TYPE}")
endif()
```

The first form is the protected RelWithDebInfo path used by the patched runtime
receipt. The import library is derived from the DLL's sibling SDK `lib`
directory; callers may pass `RUNTIME_IMPLIB` and `RUNTIME_PDB` explicitly when
the package layout is different. A patched override is rejected for a
multi-config generator or for a build whose `CMAKE_BUILD_TYPE` is not exactly
`RelWithDebInfo`.

The include performs these checks at configure time:

1. Windows x64 and the verified Clang compiler are selected.
2. The stock SDK generated CMake still contains no local codegen edits, while
   the adapted build CMake and the PowerShell helper use isolated codegen.
3. All 15 generated mission targets are present, shared libraries, linked to
   `rex::runtime`, and ordered after `cod3_pc_codegen`. The host is ordered
   after every mission target as well.
4. The host, its generated entrypoint object, every mission DLL, and the live
   coroutine/Xenon/timing targets receive
   `-ffp-model=strict`, `-fno-strict-aliasing`, and `-fwrapv`.
5. The selected runtime import pair and Xenos plugin have the expected
   configuration suffix. The patched runtime DLL/PDB and plugin are copied to
   the host output directory after linking.
6. Target sources, link properties, imported locations, and import libraries
   are scanned for Xenia references. `xenia*.exe`, a Xenia runtime/JIT, and a
   Xenia source target fail configuration. The ReXGlue `rexgpu-xenos` plugin is
   not an Xenia target and remains allowed.

`EXTRA_TARGETS` can be supplied for an additional native library or object
target. `UPSCALING_TARGET` is optional and only validates a target that the
caller has explicitly wired; when omitted, the include reports that
`integration/upscaling` remains probe-only. The include does not change the
guest clock, vblank, simulation step, or physics values.

## Bounded verification

`tests/build-system/Run.ps1` configures a small fixture against the real
generated COD3 CMake and patched SDK files. It declares inert fixture targets
with the same names, applies the contract, builds the complete 15-DLL target
graph, and checks that the patched runtime DLL/PDB, Xenos plugin, and all 15
DLL outputs are staged. It then runs the fixture's CTest smoke test.

The latest run passed with exit code 0 for configure, graph build, and CTest:

```text
-- COD3 native build contract: cod3_pc, RelWithDebInfo, 15 mission DLLs, strict FP, no Xenia runtime
100% tests passed out of 1
Build-system contract passed: <workspace>\tests\build-system\out\relwithdebinfo
```

The same runner also records two fail-closed configure checks: pairing the
RelWithDebInfo patched runtime with a Release configure returned `1`, and
injecting a fixture target named `xenia_jit` returned `1`. The positive receipt
is written to
`tests/build-system/out/relwithdebinfo/results.json` when the runner is used;
these output directories are disposable test state.

The fixture build is a native build-system check only. It does not load the
patched runtime, execute guest code, invoke XenosRecomp, run Xenia, start
`cod3_pc.exe`, or make any gameplay/FullHD/120 FPS claim. The next top-level
build should use the include above and record a fresh native-build receipt
before any runtime validation.
