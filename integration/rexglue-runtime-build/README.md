# Patched ReXGlue runtime for CoD3

This builds the `XexModule` image-reservation fix from upstream commit `0c7b01a0ac0479801757507d80533f662fa0815d` in an isolated worktree. It preserves the original `win-amd64` SDK and does not deploy files into the running game. The patch is `../rexglue-patches/0001-preserve-xex-heap-reservations.patch`.

`tools/rexglue-patched-sdk` is a full copy of the original SDK. Only **RelWithDebInfo** is patched: `bin/rexruntimerd.dll`, its import library, and the matching `XexModule` header; `bin/rexruntimerd.pdb` is added. Release/Debug DLLs in this copy remain upstream and retain the original loader behavior.

The standalone CMake project imports the verified SDK's existing fmt/spdlog/SDL3/FFmpeg/crypto/allocator libraries. It rebuilds the original core, filesystem, UI, input, audio, system, kernel, and ImGui sources, with D3D12, Tracy, profiling and performance-counter flags matching the current host. Only five upstream source submodules were fetched: CLI11, ImGui, FFmpeg (headers), libmspack (headers), and o1heap (headers). The original root SDK's entire third-party build is not required.

Rebuild:

```powershell
. '<workspace>\scripts\toolchain-env.ps1' -Quiet
cmake -S '<workspace>\integration\rexglue-runtime-build' `
  -B '<workspace>\integration\rexglue-runtime-build\build' -G Ninja `
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
cmake --build '<workspace>\integration\rexglue-runtime-build\build' --target rexruntime --parallel 4
```

The DLL/PDB are generated under `build/bin`, and its import library under `build/lib`. The source worktree already contains the checked patch. Its `git diff` is limited to the two patch files. For a fresh worktree, apply the retained patch and initialize only the five source submodules above at the commits pinned by the upstream tree.

The exact public-API heap regression source is compiled against the **original** SDK headers and `rexruntimerd.lib`, using a small wrapper that prints `GetModuleFileNameW` for the loaded runtime. It is not linked against locally compiled XexModule methods. This tests old-consumer/new-DLL compatibility under the matching RelWithDebInfo configuration. Build it with CMake using `probe-consumer` as source, `probe-build` as output, `-DCMAKE_BUILD_TYPE=RelWithDebInfo`, and `-DCMAKE_PREFIX_PATH=<workspace>/win-amd64`.

Run the exact same probe executable against both runtime directories:

```powershell
& '<workspace>\integration\rexglue-runtime-build\Run-Regression.ps1' `
  -RuntimeDirectory '<workspace>\win-amd64\bin' -ExpectedExitCode 2 -OutputStem baseline
& '<workspace>\integration\rexglue-runtime-build\Run-Regression.ps1' `
  -RuntimeDirectory '<workspace>\tools\rexglue-patched-sdk\bin' -ExpectedExitCode 0 -OutputStem patched
```

Both runs verified the actual loaded DLL path. The old runtime reproduced the defect: loading the Saint Lo guest DLL changed the main image's allocation state from 3 to 0 and incorrectly allowed an overlapping reservation. The patched runtime returned 0, preserved state 3 and the original allocation record, preserved the image bytes, and rejected overlap. The probe does not execute a guest entry point.

`verify_exports.py` compares the complete PE export tables and all imports required by the current local host, mission modules, GPU plugin, and regression probe. The parser explicitly lifts its defensive 8192-export/512-byte-name defaults because ReXGlue exceeds those limits. All 18 current consumers are covered. The rebuilt runtime has 10,231 named exports versus 10,185 upstream: 141 old exports disappear and 187 appear, mainly compiler/template internals. This is a bounded current-consumer compatibility result, not a promise of universal ABI equivalence.

`status.json`, `export-comparison.json`, the baseline/patched receipts and result JSONs, and build logs are the evidence. The separate ABI report confirms unchanged XexModule size (360), alignment (8), existing offsets, and the new ownership bool occupying former padding at offset 283. The candidate loader's 13 additional ownership/overlap/retry checks are in `analysis/runtime-module-probe-candidate.json`.

The initial replacement DLL SHA256 is `7914D5E4DDE9045C35FFE669464CA78307355412DC4A83350BA553933F569623`; the original SDK DLL remains `73A7B44ED7054E2F3961C12F3309C9E48163BF3A8757E67E3FB180184E145A8E`. Future rebuilds may change the DLL hash. The root agent stages the verified DLL into the stopped host and performs game-level validation.
