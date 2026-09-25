# Supplied Xenia package and reusable dependencies

The user-supplied archive is the **official Xenia Canary release `0e1307b`**, built from commit `0e1307bd2e6bfeeff29635a6b823e72e61c97ce9`. Its SHA256 exactly matches the Windows asset digest returned by the [official release API](https://api.github.com/repos/xenia-canary/xenia-canary/releases/tags/0e1307b). The [release](https://github.com/xenia-canary/xenia-canary/releases/tag/0e1307b) was published on 2026-09-05 at 05:05:02 UTC. This identifies the supplied artifact; no emulator or game launch was performed.

| User file | Bytes | SHA256 |
| --- | ---: | --- |
| `xenia_canary_windows.7z` | 3,641,134 | `457256BC15B7C0B1BAD8156660EE261ACB23FA7F015448E65A35EE4E8919A7BE` |
| `xenia_canary.exe` | 17,107,456 | `804A4750BAFD9C15078CC080998C58293AB5BF11D608FA7816E9A829504CDD23` |
| `LICENSE` | 1,505 | `3D58F25C15634B6EC01D1F133EF798209AE06626AB8D2227B6223D5A9F5113F4` |

The archive contains exactly **two files: EXE and LICENSE**. Both extracted payloads match the user's root files byte-for-byte. A reference copy was staged in `tools/xenia-reference-bin`; all root originals were preserved. No renderer DLL, SDL DLL, shader-compiler DLL, controller database, or shader-cache package is present in the archive.

The EXE embeds `canary_experimental@0e1307bd2 on Sep 5 2026` and the full GitHub commit URL. It has no file-version resource. The PE is x64/Windows GUI with timestamp 2026-09-05 05:04:04 UTC. It is not Authenticode-signed; provenance was checked using the official archive digest. Its only exports are the two data flags `AmdPowerXpressRequestHighPerformance` and `NvOptimusEnablement`, so it does not provide a callable renderer/plugin API for the native port.

The PE directly imports 31 DLL names, all Windows system/API-set or Visual C++ runtime dependencies; it has no delay-import table. API-set names are Windows contracts and are not assessed by searching for physical files. The four imported MSVC runtime DLLs are already installed in System32 at version 14.44.35211.0. D3D12, D3DCompiler_47, Vulkan loader, and XAudio2_8 are also present. Presence and static imports do not establish successful GPU/device initialization.

| Component | What the pinned package/source provides | Use in this native port |
| --- | --- | --- |
| Xenia D3D12 renderer | Code compiled into the EXE | Compare and adapt source changes into ReXGlue's GPU plugin, then rebuild and test. There is no renderer DLL to copy from this package. |
| SDL | Source explicitly builds **SDL2 statically** | ReXGlue uses SDL3. Keep its existing SDL3 integration; review useful input behavior at source level. SDL2 and SDL3 APIs are not an interchangeable runtime dependency. |
| FFmpeg, fmt, ImGui, zstd | Explicit static-library build targets | Reuse compatible source changes or separately built libraries only with matching versions/configuration and license notices. The EXE cannot supply those link libraries. |
| DXC, dxilconv, D3DCompiler_47 | Xenia optionally loads them for debug disassembly | They are absent from the archive. Our XenosRecomp toolchain already has an x64 DXC, `dxcompiler.dll`, and `dxil.dll` under `tools/XenosRecomp/thirdparty/dxc-bin/bin/x64`. These remain separate shader tools. |
| `gamecontrollerdb.txt` | Optional external mapping-file path | No database was shipped. A separately supplied mapping database could be integrated through SDL3 mapping APIs and checked on the actual controller. No database was copied. |
| CAS/FSR presentation code | Compiled source and shader logic | Source adaptation belongs to the renderer comparison task. An upscaler is not evidence that the game's simulation runs correctly at 120 FPS. |

Source evidence is pinned to the exact matching checkout owned by the graphics agent, `tools/Xenia-source`. [Third-party CMake](https://github.com/xenia-canary/xenia-canary/blob/0e1307bd2e6bfeeff29635a6b823e72e61c97ce9/third_party/CMakeLists.txt) declares the static libraries; [D3D12 provider lines 170–220](https://github.com/xenia-canary/xenia-canary/blob/0e1307bd2e6bfeeff29635a6b823e72e61c97ce9/src/xenia/ui/d3d12/d3d12_provider.cc#L170) classify compiler libraries as optional debugging facilities; [SDL input driver](https://github.com/xenia-canary/xenia-canary/blob/0e1307bd2e6bfeeff29635a6b823e72e61c97ce9/src/xenia/hid/sdl/sdl_input_driver.cc#L26) defines and loads external controller mappings. The graphics agent handles source-level renderer changes; this audit did not duplicate its clone.

The supplied BSD 3-Clause LICENSE is preserved beside the reference executable. Actual source reuse must retain its copyright, conditions and disclaimer, with the applicable component-specific third-party notices. The archive contains no complete third-party source/license bundle to transplant wholesale. The original ReXGlue SDK and existing DXC notices remain in place.

Repeat the static audit with `scripts/xenia-audit.ps1`; use `-Offline` to verify against the retained official release response. It never launches the EXE. Machine-readable evidence is in `xenia-dependencies.json`, with official metadata in `xenia-dependencies-release.json`. Neither native 1920×1080 output nor 120 FPS/physics correctness is established by this dependency audit.
