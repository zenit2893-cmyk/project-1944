# CoD3 native boundary v2 audit

Status: **PASS**  
Recorded (UTC): `2026-09-13T13:29:38.736491+00:00`  
Build directory: `<workspace>\cod3-pc\out\build\win-amd64-relwithdebinfo`  

This is a static audit. It did not launch `cod3_pc.exe`, `xenia_canary.exe`, the game, or an emulator.

## Result

The expected native set is `16` images: `cod3_pc.exe` plus `15` title DLLs. The build output contains `19` DLLs after adding the ReXGlue runtime, Xenos GPU plugin, coroutine helper, and Tracy dependency.

| Check | Result |
| --- | --- |
| exact fifteen title DLLs | PASS |
| expected executable and title DLLs exist | PASS |
| title images are native x64 and import ReXGlue runtime | PASS |
| local ReXGlue runtime, GPU, coroutine, and profiling DLLs are native x64 | PASS |
| no guest CPU translator or JIT marker in inspected PE strings | PASS |
| Ninja links every generated PPC C++ source for cod3_pc and 15 DLLs | PASS |
| CoD3 Ninja graph excludes Xenia emulator and guest CPU/JIT paths | PASS |
| active source boundary has no guest CPU translator/JIT implementation marker | PASS |
| XenonRecomp use is limited to the two verified adapter thunks | PASS |
| local PE import closure has no Xenia emulator dependency | PASS |
| Xenia graphics reuse is compile-only and isolated from CoD3 link graph | PASS |
| active ReXGlue runtime matches the configured patched SDK runtime | PASS |
| source provenance revisions agree with the recorded boundary receipts | PASS |
| existing native-port receipt agrees with current artifact hashes | WARN |
| xenia_canary.exe is outside the native application tree | PASS |

## Game images and hashes

| Image | Bytes | SHA-256 | Direct imports relevant to boundary |
| --- | ---: | --- | --- |
| `cod3_pc.exe` | 31831552 | `2CA96C0817651DB0CCD5940CA1D79DA99D181334015732D947815F8362BBDB7E` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_blkbrn.dll` | 11476992 | `A700EFA45EFE75039C1281A15F1353E03AE5053BCBABA8CE0D34EFB0C2C39B18` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_chambois.dll` | 12221440 | `809787FD2C28ECAE9F167015E9F0D307866FE22221861507D15FBB5D5F42FB37` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_credits.dll` | 10423296 | `BBA49B0FB28FA47E0F8E59A04110ADD09174C93BB1814FB2119F2CC28C23D965` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_crssrds.dll` | 12371968 | `249DABA0D9916FDAA77D1B4A9E5D50AABE1269D569364299646724F87C09076C` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_falaise.dll` | 11984384 | `A6EF82ED52992FEEC2F4F8B8978C27717D6269EC064A89DA6637AA487AD40959` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_forest.dll` | 11486720 | `1BDE60B15EE480FE11C1C21BE2331AEC6BCA5A3EB4EDD981E6648DF86767C495` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_fuelplnt.dll` | 11607040 | `17102A89875253B9C34DC66C4DAD5FF5A3449B4AC6148DE2235E1BC188D9B600` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_hostage.dll` | 12046848 | `23369038EFD5CBF616472FCCD5540237B078195268A068A10F7BA658F3DE4696` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_island.dll` | 12532736 | `C5680F981818EB20F3CA8B51A0C9505E2F4DCB8C5702E9ABE934B0B6FDD70294` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_laison.dll` | 12142080 | `FC42F977BF5B6D6F91B445B9625AF7158FF4CC50BE02A89820D44E68EE042B6B` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_mace2.dll` | 13287424 | `DEF85FE4E015FA5D62DC51448869D6C5254EF93B7CE4FEE1B2644C42D2D5E75B` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_mayenne.dll` | 11932160 | `C4AD76C7D91A3FAB53466ADE0843EF47988B1CF4AE30BAF08A37100462D387FC` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_nightd.dll` | 11634688 | `E6919C8B352D6D6638465040196C43BD7E7526523938835561AB6B85774151EC` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_saint_lo.dll` | 12948992 | `CE03E39591F3A9E2837DCA123764058ED431835F5E271F91DFEAB2B448CF5A80` | cod3_coroutines.dll, rexruntimerd.dll |
| `cod3_pc_stbert.dll` | 11807232 | `03DC8CB26B9698A67AF9355ED7E2D19A789D019B11FCD620593BD3EC94A2C5C7` | cod3_coroutines.dll, rexruntimerd.dll |

## Local import closure

| Image | Local imported DLLs | System/API imports |
| --- | --- | --- |
| `cod3_pc.exe` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `SHELL32.dll`, `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `ole32.dll` |
| `cod3_pc_blkbrn.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_pc_chambois.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_pc_credits.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_pc_crssrds.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_pc_falaise.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_pc_forest.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_pc_fuelplnt.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_pc_hostage.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_pc_island.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_pc_laison.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_pc_mace2.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_pc_mayenne.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_pc_nightd.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_pc_saint_lo.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_pc_stbert.dll` | `cod3_coroutines.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll` |
| `cod3_coroutines.dll` | `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll` |
| `rexruntimerd.dll` | `TracyClientrd.dll` | `ADVAPI32.dll`, `GDI32.dll`, `IMM32.dll`, `KERNEL32.dll`, `MSVCP140.dll`, `MSVCP140_ATOMIC_WAIT.dll`, `SETUPAPI.dll`, `SHELL32.dll`, `USER32.dll`, `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`, `VERSION.dll`, `WINMM.dll`, `WS2_32.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `bcrypt.dll`, `dxgi.dll`, `ole32.dll` |
| `rexgpu-xenosrd.dll` | `TracyClientrd.dll`, `rexruntimerd.dll` | `KERNEL32.dll`, `MSVCP140.dll`, `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `ole32.dll` |
| `TracyClientrd.dll` | — | `ADVAPI32.dll`, `KERNEL32.dll`, `MSVCP140.dll`, `USER32.dll`, `VCRUNTIME140.dll`, `WS2_32.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `dbghelp.dll` |

The runtime also has a dynamic plugin name for the local Xenos GPU DLL. This is string/import-loader evidence; static analysis cannot prove the runtime actually resolves it on every host:

- `rexruntimerd.dll` → `rexgpu-xenosrd.dll` (`PE string rexgpu-{}{}.dll plus LoadLibrary/GetProcAddress imports`)

## Generated PPC C++ and Ninja link proof

| Target | Generated source list | All generated objects in link header | Link header line |
| --- | ---: | --- | ---: |
| `cod3_pc.exe` | 94 | PASS | 6654 |
| `cod3_pc_blkbrn.dll` | 30 | PASS | 450 |
| `cod3_pc_chambois.dll` | 32 | PASS | 890 |
| `cod3_pc_credits.dll` | 28 | PASS | 1282 |
| `cod3_pc_crssrds.dll` | 32 | PASS | 1722 |
| `cod3_pc_falaise.dll` | 31 | PASS | 2150 |
| `cod3_pc_forest.dll` | 30 | PASS | 2566 |
| `cod3_pc_fuelplnt.dll` | 31 | PASS | 2994 |
| `cod3_pc_hostage.dll` | 32 | PASS | 3434 |
| `cod3_pc_island.dll` | 33 | PASS | 3886 |
| `cod3_pc_laison.dll` | 32 | PASS | 4326 |
| `cod3_pc_mace2.dll` | 35 | PASS | 4802 |
| `cod3_pc_mayenne.dll` | 31 | PASS | 5230 |
| `cod3_pc_nightd.dll` | 31 | PASS | 5658 |
| `cod3_pc_saint_lo.dll` | 34 | PASS | 6134 |
| `cod3_pc_stbert.dll` | 31 | PASS | 6562 |

The executable link header contains the XenonRecomp adapter object from `integration/xenon`, but does not contain the full `analysis/title-xenon-generated` tree. The adapter provenance limits this to two exact branch thunks; the remaining generated guest code is ReXGlue output.

## Xenia isolation and provenance

The Xenia graphics change is represented by a pinned source patch and a separate CMake `OBJECT` target. That target compiles one adapted D3D12 texture-cache translation unit against ReXGlue headers; it has no executable or shared-library link step and is absent from the CoD3 Ninja graph. The active CMake target requests the ReXGlue `rexgpu-xenosrd.dll` plugin, whose GPU/Xenos semantics are allowed by this boundary policy; the PE string/import evidence shows the runtime's dynamic plugin loader, while successful resolution still needs a runtime test. No Xenia emulator binary is part of the application closure.

| Source or artifact | Revision/hash evidence | State |
| --- | --- | --- |
| `tools/rexglue-source` | `0c7b01a0ac0479801757507d80533f662fa0815d` | present |
| `tools/XenonRecomp` | `ddd128bcca99fe8bfbb99bea583c972351fa6ace` | present |
| `tools/XenosRecomp` | `990d03b28a27b50277ee5d8d942e1c5f873869d1` | present, dirty checkout |
| `tools/Xenia-source` | `0e1307bd2e6bfeeff29635a6b823e72e61c97ce9` | present |
| `integration/xenia-graphics/point-sampling-provenance.json` | `A52B5BA7CB873251CA4E7422559CE7469A89B8C26BBF22D4E070F18F084B9722` | present |
| `integration/xenia-graphics/rexglue-point-sampling.patch` | `66E47102B79801E6CB35B96D6228BFA400ACEF71B3DEEBE25EBACD7B55D333D3` | present |
| `integration/xenia-graphics/XENIA-LICENSE` | `3D58F25C15634B6EC01D1F133EF798209AE06626AB8D2227B6223D5A9F5113F4` | present |
| `integration/xenia-kernel/0001-forward-xam-message-box-ui-ex.patch` | `29F17B9B5CB5FDE109339A3A890CDAF3758C73B3F906F4B07F05F73705E66B61` | present |
| `integration/xenia-kernel/candidate/src/kernel/xam/xam_ui.cpp` | `5067F1ED5471F43E71A909ACA57141AA6235412FF364FABA6F60CF6923BC7CD6` | present |
| `integration/xenon/generated/thunks.provenance.json` | `ED6FC29AEBD3C61DB6987146A88190E61893F7BBFE0C4D80DB0AD2648DB692B2` | present |
| `integration/xenon/generated/thunks.generated.inl` | `073812351693534FCD6DC0A7732B63E5156BB236C0C29599BD0DB0EF42B3841D` | present |
| `integration/xenia-graphics/CMakeLists.txt` | `A61A36ABEA3758A5D37F82C26AD683E873B17967F7949EDAC84B799D22B4DC1C` | present |
| `integration/xenon/CMakeLists.txt` | `01333A13F547CBBB18FB2900ED5F3505EC37D70CE1C71B8605FE5D84AD7B5775` | present |
| `cod3-pc/CMakeLists.txt` | `3F34A5254AE2C2614D9878716B967DC9C5BB10626F38D75922A1830A2A99027D` | present |
| `cod3-pc/cod3_pc_manifest.toml` | `367AECB80FD66F724134AC1DA7138C1EA98FAD2BCB1560675410230FFD2B9963` | present |
| `cod3-pc/out/build/win-amd64-relwithdebinfo/build.ninja` | `3B69041EBD29E8DF2B772CFFD4FDE9A0CCFD298B0D48BF6A1882936C56761381` | present |
| `analysis/cod3-pc-native-build-receipt.json` | `8D48D6C7BEFDA5681C69793165099D0E1CF64DAA57ACA3CEB33A1BB1621EAFAD` | present |
| `analysis/cod3-boundary-evidence.json` | `5CEF7E22D1D2A438C0201508EEE065C03A609BC5FAC12C26F709606247B18D08` | present |
| `analysis/cod3-pointer-boundary-evidence.json` | `827BBB5D0514CBA4087849E577204D0B9941F5F1C02C14A8C01A08C973CE389A` | present |
| `docs/reports/xenia-dependencies.json` | `01C077BDF20E1699D18607EE3F4C680F12B6984444C94AE6180CE0E115441A0E` | present |
| `docs/reports/sdk-xenon-interop.md` | `F9CECDEABBA636BC0497E1F616768FC5275AD75A6139A024F11990F60068596A` | present |

The supplied `xenia_canary.exe` is retained at the workspace root for provenance only; it is outside the native build tree and is not an application dependency:

- `xenia_canary.exe` — `804A4750BAFD9C15078CC080998C58293AB5BF11D608FA7816E9A829504CDD23`
- `xenia_canary_windows.7z` — `457256BC15B7C0B1BAD8156660EE261ACB23FA7F015448E65A35EE4E8919A7BE`

The PE string scan found Xenia terminology only in the ReXGlue runtime/plugin, where it belongs to the Xenos GPU compatibility implementation. It found no guest CPU translator or JIT marker:

- `rexruntimerd.dll`: 9 Xenia/GPU compatibility strings; examples: `?ToXeniaProtectFlags@memory@rex@@YA?AW4PageAccess@12@K@Z`; `D3D12Presenter: Tried to create a swap chain for an unsupported Xenia surface type`; `FFmpeg version xenia-premake`; `Failed to create a Direct3D 12 direct command queue with global realtime priority, falling back to high priority, try launching Xenia as administrator`
- `rexgpu-xenosrd.dll`: 15 Xenia/GPU compatibility strings; examples: `1D texture has packed mips enabled in the fetch constant, but this appears to be completely wrong - ignoring! Report the game to Xenia developers`; `1D texture has tiling enabled in the fetch constant, but this appears to be completely wrong - ignoring! Report the game to Xenia developers`; `1D texture is too wide ({}) - ignoring! Report the game to Xenia developers`; `Memexport done to an unresearched format {}, report the game to Xenia developers!`

## What this proves and what it does not

It proves that the inspected Windows build is x64, that the executable and fifteen title DLLs are linked from generated PPC C++ object files, that they import the ReXGlue runtime, and that the local PE/link graph contains no Xenia emulator dependency or guest CPU/JIT marker found by these checks. It records the current hashes so a later build cannot be mistaken for this one.

It does not prove complete game compatibility, dynamic DLL search-path success, that every optional runtime branch is unreachable, that a GPU device initializes, that the Xenia-derived source patch has been behaviorally validated in a live frame, or that 120 FPS preserves game logic and physics. Those require runtime and differential tests.

Existing native-port receipt comparison: `False` for the executable hash and `False` for the recorded DLL hashes.
