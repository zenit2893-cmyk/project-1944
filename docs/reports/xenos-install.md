# XenosRecomp installation and verification

The official [hedge-dev/XenosRecomp](https://github.com/hedge-dev/XenosRecomp) repository was cloned recursively into `tools/XenosRecomp` at commit `990d03b28a27b50277ee5d8d942e1c5f873869d1`, built successfully and executed on this PC. A local, explicitly selected CoD3 adapter now converts all **610 programs in the prepared 437-container corpus** to HLSL, DXIL libraries and SPIR-V. All five pinned submodules are present. Exact revisions, executable SHA-256 and local patch SHA-256 are recorded in `xenos-install.json` beside this report.

**Compiler acceptance does not establish correct shader behavior.** A separate active-instruction audit found **63 programs with known unsupported texture-gradient operations**. Their generated files are analysis artifacts; they must not be treated as verified rendering code. The native converter reports this known gap, and each affected program is explicitly marked in the batch report. No generated shader is currently established as correctly integrated with the game renderer.

XenosRecomp translates Xbox 360 GPU shader containers into HLSL. Its directory mode also invokes DXC to create a C++ DXIL/SPIR-V cache in the format used by Unleashed Recompiled. It does not translate the PowerPC game executable or provide a Call of Duty 3 renderer. The installed repository contains its upstream MIT license and dependency files.

## Rebuild and run

From the workspace root in PowerShell 7:

```powershell
.\scripts\xenos-build.ps1 -Jobs 4
.\scripts\xenos-shader.ps1 -InputPath '.\path\to\shader.bin' -OutputPath '.\analysis\shader.hlsl'
.\scripts\xenos-shader.ps1 -CoD3Legacy -InputPath '.\path\to\cod3-shader.bin' -OutputPath '.\analysis\cod3-shader.hlsl'
.\scripts\xenos-shader.ps1 -CoD3Legacy -Entry Primary -InputPath '.\path\to\dual-shader.bin' -OutputPath '.\analysis\primary.hlsl'
.\scripts\xenos-shader.ps1 -CoD3Legacy -Entry Secondary -InputPath '.\path\to\dual-shader.bin' -OutputPath '.\analysis\secondary.hlsl'
.\tools\toolchain\bootstrap-python\Scripts\python.exe .\scripts\xenos-batch.py --workers 4
```

The build script imports `scripts/toolchain-env.ps1`, configures CMake/Ninja with Clang and builds only the `XenosRecomp` target in Release mode. The shader wrapper checks input/output paths, the basic shader container signature and presence of reflection data. It uses relative paths so the Cyrillic workspace prefix is not passed through the upstream narrow `char**` file interface. Conversion can still fail for game formats or features the upstream converter does not implement. Existing outputs require `-Force` before being replaced; zero-shader directory scans are reported as failures.

Installed executable: `tools/XenosRecomp/build/XenosRecomp/XenosRecomp.exe` (732,160 bytes), with `dxcompiler.dll` and `dxil.dll` beside it. SHA-256: `71217CA2B8C4BE63876772F9009C525BAA619AFF9D2035C2012991E450F648F1`. The no-argument CLI works without loading the compiler environment first.

The native equivalents of the wrapper options are `--cod3-legacy-container`, `--cod3-legacy-primary` and `--cod3-legacy-secondary`. Dual-program containers require individual file input and explicit entry selection. Batch output maps each result by original container SHA-256 plus entry; the input bytes are never rewritten.

The complete local source change is preserved as `docs/reports/xenos-cod3-adapter.patch`, relative to the pinned upstream commit. It changes five source files; it is not an upstream release.

## Verification record

- Recursive clone and all submodule checkouts completed successfully.
- Both added PowerShell scripts passed parser validation.
- Bundled DXC `--version` completed with exit code 0: `dxcompiler.dll 1.8.2407.7 (416fab6b5)`, `dxil.dll 1.8.2407.12`.
- Bundled DXC compiled a handwritten pass-through vertex shader to a 2,812-byte DXIL binary and a 328-byte SPIR-V binary, both with exit code 0. Files are under `tools/XenosRecomp/build-smoke/`. This is a toolchain smoke test, not a game shader test.
- XenosRecomp Release build completed all 49 compilation/link steps with Clang 22.1.8 (`clang-cl`), MSVC 14.44.35207 headers/libraries and Windows SDK 10.0.26100.0. The base checkout built without patches; the CoD3 adapter was subsequently added and rebuilt. `BUILD_SHARED_LIBS=OFF` is pinned to keep repeated CMake configurations consistent.
- Both the build-script invocation and a separate no-environment invocation of `XenosRecomp.exe` printed the expected usage line and exited with code 0. Safe probe: invoke the executable with no arguments.
- A controlled empty-directory scan reached the native cache/compression path; the wrapper correctly rejected its zero-shader output. An ordinary HLSL file was also rejected as an unsupported Xbox shader container before native conversion.
- The final batch converted 437 original containers, comprising 246 pixel programs and 364 vertex programs when both entries in 173 dual-program containers are counted separately. All 610 HLSL generations, all 610 DXIL library compilations and all 610 SPIR-V compilations passed. Every source hash matched the extraction manifest and remained unchanged after conversion. The final batch took 13.141 seconds with four workers.
- Native gradient-gap diagnostics appeared for exactly 63 programs, matching the independent active-instruction audit and the batch manifest's semantic blocker records.
- Actual wrapper tests generated separate primary and secondary outputs from a dual-program container; omitting explicit entry selection was rejected.

Per-program input/output SHA-256, entry offsets, native input mapping, exact commands and complete compiler logs are indexed by `docs/reports/xenos-cod3-shaders.json`. Artifacts are under `tools/XenosRecomp/build-cod3-shaders`. The final manifest references 8,925,356 bytes of HLSL, 3,527,216 bytes of DXIL libraries and 7,222,660 bytes of SPIR-V.

## CoD3 adapter evidence

The old `0x102A1000/1001` containers use definition lists starting at offset `+0x20`; upstream's newer format uses `+0x14`. The graphics analysis independently checked this legacy layout across 430 definition tables. Containers with flags `0x102A1021` contain a second definition table and shader header in the auxiliary offsets; both entries are converted separately, with no assumption about when the game selects them. All 173 auxiliary pairs passed metadata bounds checks.

Reflection and active microcode comparisons established the pixel boolean bank offset of 128 and vertex sampler bank offset of 16. Vertex inputs with repeated POSITION0/NORMAL0 semantics retain distinct symbols and Vulkan locations identified by their original microcode instruction addresses. These addresses are not host buffer identifiers: some guest fetch instructions are runtime-patched placeholders, so native input binding still needs the guest vertex declaration.

Three grass vertex programs use `SetTextureLod` followed by explicit-register texture fetches. The adapter preserves the scalar value from `r1.w` or `r0.y` and uses `SampleLevel`, including instruction LOD bias. It does not replace the value with a fixed mip level. Dynamic sampler LOD bias, base-map mode and clamp state still require correct runtime binding; their values cannot be recovered from a static shader container. Evidence is in `analysis/graphics-grass-texture-fetch.json` and the installed ReXGlue source `src/graphics/pipeline/shader/dxbc_translator_fetch.cpp`.

The active-instruction audit additionally found 332 `GetTextureGradients`, 30 `SetTextureGradientsHorz`, 30 `SetTextureGradientsVert` and 36 texture fetches using register gradients, affecting 63 programs. These operations are not implemented by the adapter. The 36 explicit-gradient samples include 9 2D and 27 cube samples; a simple 2D-only derivative replacement would leave substantial behavior unresolved. `analysis/graphics-texture-feature-inventory.json` records the active control-flow/EXEC-selected instructions. The compiler report links this evidence and records each affected instruction under `known_semantic_blockers`.

## Boundaries for Call of Duty 3

Upstream explicitly describes the converter as requiring adaptation for each game. Its shader container and renderer assumptions originate from Sonic Unleashed. Reflection data is required. The local adapter addresses the observed legacy container, bank, input and register-LOD cases; it does not establish support for all GPU instructions, formats, dynamic register indexing, memory export, integer state or rendering modes. See the installed `README.md` and [upstream implementation notes](https://github.com/hedge-dev/XenosRecomp/blob/990d03b28a27b50277ee5d8d942e1c5f873869d1/README.md).

DXIL outputs are Shader Model 6.3 libraries and still need runtime specialization/linking. These files are not automatically consumable by the ReXGlue renderer, and the Unleashed-style directory cache is not claimed to be compatible with ReXGlue. The prepared extraction selected blocks by source path and declared size, which does not prove complete shader coverage for all game data. No rendering correctness or 120 FPS gameplay claim follows from compiler success. Native renderer binding, runtime entry selection, instruction behavior and visual comparisons remain separate checks.
