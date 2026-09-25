# Call of Duty 3 multiplayer native target

This report records an isolated native target for the second executable on the
disc, `codmp_xenonf.xex`. The target uses the installed ReXGlue runtime and
Xenos GPU plugin, while its generated PPC image, function table, entrypoint,
and output directory are independent of the single-player target. No game
window, emulator, network session, or multiplayer match was launched during
this work.

## Input identity and image layout

The MP XEX was read from the extracted disc directory and checked with the
same local XEX2 parser and basic-image reconstruction used for the SP audit.

| Property | MP value |
|---|---|
| Source | `game/cod3/codmp_xenonf.xex` |
| XEX size | 7,122,944 bytes |
| XEX SHA-256 | `BD57D0DF66172ED58163FCFB8A814640DDDDA3DAC07CE2D6B79BF226B20982F6` |
| Title ID / media ID | `415607E1` / `2E07093A` |
| Version / base version | `0.0.0.1` / `0.0.0.1` |
| Original PE name | `codmp_xenonf.pe` |
| XEX format | normal encryption, basic compression |
| Guest image base | `0x82000000` |
| Guest entrypoint | `0x823140C8` |
| Reconstructed image size | 14,811,136 bytes (`0xE20000`) |
| `.text` address / size | `0x820B0000` / `0x4F21D4` |
| Reconstructed image SHA-256 | `5231F2814FB4DB3ADFF62368B186A7681409E20D7D6F12C489E8CC34A3886248` |
| Xenia-style code-page hash | `67AEBDFD98156710`, range `0x820B0000..0x825B0000` |

The SP image has the same guest base but a different entrypoint and image
layout: its entrypoint is `0x82344D00`, `.text` starts at `0x820A0000`, and
its generated image size is `0xC30000`. Those differences are why the MP
target has its own `PPCImageInfo` and function mapping. Reusing the SP map for
MP would dispatch guest addresses against the wrong generated functions.

The machine-readable records are
[`mp-title-metadata.json`](../../integration/mp-target/mp-title-metadata.json)
and [`mp-image.json`](../../integration/mp-target/mp-image.json). The
reconstructed binary is local game-derived analysis data.

## Separate code generation

The isolated XenonRecomp configuration is
[`mp-xenon.toml`](../../integration/mp-target/mp-xenon.toml). XenonAnalyse
produced its own jump-table file, and XenonRecomp completed a separate pass in
`integration/mp-target/xenon-generated`:

- 100 output files, 97,899,565 bytes total;
- exit code 0 and a completed `Recompiling functions... 100%` line;
- 75 unrecognized instruction occurrences: `vandc` (31), `vsel128` (13),
  `vrfip` (11), `mfctr` (6), `vaddsbs` (3), `vsrb` (3), `bdnzt` (2),
  `vpkswss` (2), `mulhdu` (1), `vcmpgtsw.` (1), `vctuxs` (1), and
  `vsubsbs` (1);
- 1,205 switch-case-outside-function diagnostics at 84 unique sites.

The Xenon output is retained as an independent diagnostic/reference pass. It
is not linked into `cod3_mp`: the unresolved SIMD operations, switch-boundary
diagnostics, and the different Xenon context/runtime contract have not been
reviewed for a whole-program native bridge. This keeps the AOT native target
on the ReXGlue-generated ABI while still preserving the Xenon evidence for
future, function-by-function review.

## ReXGlue MP target

The SDK project created for the MP executable is under
[`integration/mp-target/rexglue`](../../integration/mp-target/rexglue):

- [`cod3_mp_manifest.toml`](../../integration/mp-target/rexglue/cod3_mp_manifest.toml)
  names `cod3_mp` and points to `codmp_xenonf.xex`;
- [`CMakeLists.txt`](../../integration/mp-target/rexglue/CMakeLists.txt) defines
  the independent `cod3_mp` executable and calls
  `rexglue_setup_target(cod3_mp GPU_PLUGINS xenos)`;
- [`src/cod3_mp_app.h`](../../integration/mp-target/rexglue/src/cod3_mp_app.h)
  overrides the SDK default `game:\\default.xex` path with
  `game:\\codmp_xenonf.xex`;
- [`cmake/ReXGlueProject.cmake`](../../integration/mp-target/rexglue/cmake/ReXGlueProject.cmake)
  keeps the codegen manifest argument relative to the project working
  directory. The installed Windows SDK otherwise parses the Cyrillic absolute
  path through a narrow API and falsely reports that `[project]` is missing.

The first strict ReXGlue pass found one real boundary gap and stopped before
writing code:

```text
UnresolvedCall (1):
  0x82298D38 from 0x822990E4: b 0x82298D38 from 0x822990E4 - target not in any function
```

The decoded MP image contains the exact eight-byte tail thunk at that address:

```text
0x82298D38: 38630004 4BFF72E4   addi r3,r3,4; b 0x82290020
0x82298D40: 7D8802A6 ...        next function prologue
```

That evidence is declared as `0x82298D38 = { size = 8 }` in the MP manifest.
The second ReXGlue pass then validated and wrote the complete native output:

- 88 generated recompilation C++ units;
- 88 per-file declaration headers;
- 23,358 function-mapping entries in the generated initializer;
- `PPCImageInfo` with MP-specific `REX_IMAGE_SIZE 0xE20000`,
  `REX_CODE_BASE 0x820B0000`, and `REX_CODE_SIZE 0x4F21D4`;
- generated mapping entry `{ 0x823140C8, xstart }`.

The generated files remain in the private local directory
`integration/mp-target/rexglue/generated/codmp_xenonf` because they are
derived from the supplied game executable.

The MP generated import surface is larger than the SP surface. The MP XEX has
288 `xboxkrnl.exe` import records and 156 `xam.xex` records, compared with 282
and 86 in the SP XEX. Its generated declarations include
`NetDll_XNetStartup`, `NetDll_XNetConnect`, `NetDll_socket`, `NetDll_sendto`,
`NetDll_recvfrom`, `NetDll_XNetQosListen`, `NetDll_XNetQosLookup`, and
`XamSessionCreateHandle`. These names establish which network/session paths
must be audited for the MP target. They do not establish that the current SDK
implements the full service, NAT, authentication, or peer synchronization
contract.

## Native build result

After configuring with the pinned Windows toolchain and the local ReXGlue SDK,
the isolated project compiled and linked successfully in
`RelWithDebInfo`. The resulting executable is
[`cod3_mp.exe`](../../integration/mp-target/rexglue/out/build/win-amd64-relwithdebinfo/cod3_mp.exe)
with:

- size: 31,771,648 bytes;
- SHA-256: `C81A322394A4EFD7020E405E32CC424448C2DB776733CC082798A05B04C7DD3A`;
- alongside the matching ReXGlue runtime and Xenos GPU plugin DLLs.

The build proves that the separate MP generated code and launcher wiring are
accepted by the native compiler/linker. It does not prove that the guest boots,
renders a menu, connects to services, loads an MP map, synchronizes peers, or
preserves gameplay behavior.

## Verification and remaining blockers

Run the static/build artifact checks with:

```powershell
pwsh -NoProfile -File .\tests\mp-target\Run.ps1
```

Add `-Build` to reconfigure and rebuild the isolated target. The latest receipt
is [`tests/mp-target/results.json`](../../tests/mp-target/results.json), with all
17 checks passing. It explicitly leaves `multiplayer_verified` and
`fps_120_verified` false.

The target is ready for the next bounded phase: native boot diagnostics and a
separate review of the MP network/service imports. An SP-to-MP handoff still
needs a process-level launcher or a runtime API that can safely construct a
new `PPCImageInfo`/function-dispatch context. Calling the current guest title
launch path from SP cannot reuse this MP map in the same runtime. No such
handoff or gameplay workaround was added here, and no clock or physics scalar
was changed.
