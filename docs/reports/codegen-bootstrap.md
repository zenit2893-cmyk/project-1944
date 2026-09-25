# COD3 ReXGlue project and strict code generation

Active project: `cod3-pc`, CMake target and manifest project name `cod3_pc`.
The earlier `cod3` project remains preserved as the successful main-executable baseline.
This report records code generation only. Native build, boot, gameplay, and 120 FPS
validation are independent stages owned by the integration and validation work.

## Inputs and SDK

- SDK executable: `win-amd64/bin/rexglue.exe`, `0.10.0.5-dev.g0c7b01a`.
- CMake package version pinned to `0.10.0.5`; source commit
  `0c7b01a0ac0479801757507d80533f662fa0815d`.
- Main XEX: `game/cod3/default.xex`, 7,254,016 bytes.
- Main SHA256: `2944EEC7D1231AD6798B5F9F8ADF8855F5E489296B22EAB45B27A577CEE23692`.
- SDK-loaded title ID `415607E1`, media ID `2E07093A`, executable version `0.0.0.1`.
- All 15 single-player mission DLLs are real guest XEX modules. Their manifest
  paths retain the full disc paths, such as `sp/saint_lo/saint_lo.dll`.
- `codmp_xenonf.xex` is a separate executable and is not represented as a
  single-player mission module or claimed to have been recompiled here.

## Results

The main executable and all 15 mission modules passed ReXGlue analysis with normal
validation and without `--force`. Every mission pass returned exit code 0. Native
module registration and CMake targets include all 15 missions.

| Target | Generated function bodies | C++ files |
| --- | ---: | ---: |
| default | 19,122 | 94 |
| blkbrn | 5,726 | 30 |
| chambois | 5,928 | 32 |
| credits | 5,273 | 28 |
| crssrds | 6,155 | 32 |
| falaise | 5,784 | 31 |
| forest | 5,655 | 30 |
| fuelplnt | 5,815 | 31 |
| hostage | 6,138 | 32 |
| island | 6,143 | 33 |
| laison | 5,910 | 32 |
| mace2 | 6,221 | 35 |
| mayenne | 5,983 | 31 |
| nightd | 5,827 | 31 |
| saint_lo | 6,043 | 34 |
| stbert | 5,906 | 31 |
| **Total** | **107,629** | **567** |

These are the initial successful codegen counts, before the native-boot boundary
follow-up below. They count generated `DEFINE_REX_FUNC` bodies, including library
helpers, and are not estimates of identified gameplay functions. Initial output is approximately
573 MB and remains local because it derives from the supplied game binaries.

Receipts and logs:

- `analysis/cod3-pc-codegen-receipt.json`: aggregate result, main hash, manifest
  hash, output counts, and pointers to per-module receipts.
- `analysis/cod3-pc-module-codegen-receipts.json`: each module input hash and exit.
- `analysis/cod3-pc-generated-statistics.json`: per-module counts.
- `logs/cod3-pc-codegen-isolated.log`: successful complete wrapper run.
- `logs/cod3-pc-codegen-<mission>.log`: latest selected-module compiler log;
  incremental runs may report outputs already up to date.
- `logs/cod3-pc-codegen.log`: retained failed initial attempt with all overlapping
  modules loaded together. It is evidence of the SDK limitation, not the final status.

## Evidence-backed boundary corrections

Unmodified main analysis stopped on two direct branch targets missed by function
discovery. The exact loaded machine words establish two tiny standalone thunks:

- `0x822D0498`, 4 bytes: `4BFFFC80`, a branch to `0x822D0118`, followed by a
  zero padding word before the next function at `0x822D04A0`.
- `0x822D2140`, 8 bytes: `38630004` (`addi r3,r3,4`) and `4BFF98E4`
  (branch to `0x822CBA28`), ending at the known function `0x822D2148`.

These were the two initial boundaries added to `[entrypoint.functions]`. No game instructions
were replaced, no function was stubbed, and no clock or physics setting changed.
`analysis/cod3-boundary-evidence.json` records callers and words. A separate title
analysis agent independently confirmed the bytes. The loaded image capture is
documented in `analysis/cod3-loaded-image-receipt.json` and was read exclusively
from the compiler process launched by `analysis/capture-cod3-loaded-image.ps1`.

### Native-boot follow-up

The integration process subsequently built the combined native application. Its
first run reached the RTX 5070 D3D12 device, graphics pipeline creation, and audio
client initialization, then reported an unregistered guest function at
`0x822C27F8` in `logs/cod3-pc-run-20260905-081952.log`.

The exact original code identifies a 132-byte standalone dispatch function at that
address, referenced by a static table at `0x82049BB0`. It follows the previous
function's `bctr`, includes a local branch to `0x822C286C`, and ends at `0x822C287C`
before zero padding. Independent XenonRecomp discovery also identifies its start.

A read-only static sweep compared the independent XenonRecomp mapping with the
ReXGlue registration table. Of 714 differing entries, 57 appeared as pointers in
static `.rdata` or `.data`. Manual instruction review selected 35 self-contained
leaf functions and adjustor thunks, including the observed crash address, for
exact boundary declarations. The other referenced entries include exception
continuations and were left unchanged; unreviewed differences were not imported.

The manifest now contains the initial two thunks plus these 35 declarations.
`analysis/cod3-pointer-boundary-evidence.json` records every selected address,
size, instruction, and static reference; `analysis/cod3-pointer-sweep.py` and its
JSON output record the larger comparison. The boundary update was handed to the
integration process for regeneration, native build, and another actual boot.
It changes discovery metadata only and retains all guest instructions and clocks.

## SDK limitations handled in the project

The Windows SDK uses a narrow string path when parsing TOML. Passing an absolute
manifest path containing the Cyrillic workspace directory falsely reports a
missing `[project]` section. A relative manifest argument from the project directory
works. Included TOML files also become absolute narrow paths internally, so the two
boundary settings are inline in the manifest.

All 15 mission overlays share guest base `0x89000000`. This SDK's
`ProjectRecompiler::Run` loads all selected modules into a shared runtime before
copying/analysing them and later rejects overlapping address ranges. Full-module
codegen therefore reads overwritten overlay bytes and fails. Passing just one
`--target <mission>` per fresh process succeeds without mission boundary overrides.

`cod3-pc/cmake/Invoke-Codegen.ps1` implements that isolated sequence. After each
success it retains the SDK's exact native module CMake fragment. At the end it
combines all 15 fragments, creates the full registry using the SDK API, and writes
a UTF-8 depfile covering the manifest, helper, main XEX, and all mission XEXs.
The stamp is written only after every module and complete registry succeeds.

`cod3-pc/cmake/ReXGlueProject.cmake` substitutes this helper for the upstream custom
codegen command at configure time. The SDK-generated source file stays intact;
the adapted CMake file is written to the build directory. An unexpected SDK command
format fails explicitly so an SDK upgrade cannot silently bypass overlay isolation.

The SDK occasionally prints `BaseHeap::Release failed because address is not a
region start` while tearing down a tool-mode runtime containing a mission DLL.
Selected-module analysis and generation still return 0. This diagnostic is recorded
as an SDK cleanup issue, not suppressed or presented as runtime gameplay evidence.

## Integration handoff

The CMake application uses `rexglue_setup_target(cod3_pc GPU_PLUGINS xenos)`, the
matching ReXGlue runtime ABI, and normal clock/timing defaults. It does not force a
120 Hz guest clock or change a simulation time scalar. Build and launch wrappers
must use the active `cod3-pc` project and let its custom target invoke the isolated
codegen helper. Calling stock `rexglue codegen` without `--target` on the full
manifest reproduces the known overlay limitation.

Compilation and launch must still validate imported APIs, guest DLL overlay
load/unload, shaders, audio, input, and actual mission behavior. Generated C++ and
a complete registry alone do not establish a playable port or physics preservation
at 120 FPS.
