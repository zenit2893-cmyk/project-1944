# FullHD spatial presenter integration

This report records the isolated presenter work for the Plan B native port. It
targets a 1920x1080 host render target while keeping the guest front-buffer
dimensions, guest display aspect ratio, guest video-mode refresh source, and
guest clock contract outside this patch. It does not claim that Call of Duty 3
now renders at 120 FPS or that gameplay and physics have been validated.

The source overlay is reproducible with:

```powershell
& '.\integration\upscaling\Run-Probe.ps1' -Jobs 2
```

`prepare_overlay.py` reads the pinned ReXGlue tree, makes a reversible overlay
under `integration/upscaling/overlay`, emits `rexglue-spatial.patch`, and writes
`overlay-manifest.json` with source and output hashes. The active SDK tree,
`cod3-pc`, generated game code, and game data are not modified. The overlay
contains the six presenter/header translation units plus the two CMake fragments
needed to apply the same feature split to a future SDK build.

The generated patch passes `git -C tools/rexglue-source apply --check`; applying
it is therefore an explicit, reviewable choice. The unmodified source tree was
left clean after the check, and the overlay can be discarded independently.

## What is real and enabled

The pinned ReXGlue source is commit
`0c7b01a0ac0479801757507d80533f662fa0815d`. Its presenter already contains the
spatial pass topology used here:

| Guest output | 1920x1080 host behavior |
| --- | --- |
| 1280x720 with `fsr` | one FSR1 EASU pass to 1920x1080, then RCAS |
| 640x360 with `fsr` | two chained EASU passes, then RCAS |
| 1280x720 with `cas` | one CAS resample pass to 1920x1080 |
| 16:9 source and 16:9 host | no letterbox rectangle |

The existing ReXGlue D3D12 bytecode headers are concrete shader blobs, not
placeholders. They contain valid DXBC containers, resource-definition and
shader-program chunks, and the cbuffer field names consumed by the presenter:
EASU input/output ratio and inverse input size, RCAS output offset and
sharpness, and CAS output offset, input/output ratio, and sharpness. The native
probe checks all seven spatial blobs; the real D3D12 presenter translation unit
also compiles all seven headers, including dither variants.

The overlay uses two independent capability gates:

```text
REXGLUE_ENABLE_SPATIAL_UPSCALING=ON
REX_HAS_FIDELITYFX_SPATIAL=1
REXGLUE_ENABLE_FIDELITYFX=OFF
REX_HAS_FIDELITYFX_RUNTIME is absent
```

With the runtime gate absent, the `present_effect` CVar exposes only
`bilinear`, `cas`, and `fsr`. The `fsr2` and `fsr3` parser branches remain
behind the runtime gate and therefore fall back to bilinear in this build.
There is no temporal history, motion-vector, depth, exposure, or frame
generation resource added by this patch. The runtime FidelityFX API is not
linked and no temporal context is created.

## Xenia provenance and impact

The local Xenia source is commit
`0e1307bd2e6bfeeff29635a6b823e72e61c97ce9`, under the BSD-3-Clause license in
`tools/Xenia-source/LICENSE` (SHA-256
`3d58f25c15634b6ec01d1f133ef798209ae06626ab8d2227b6223d5a9f5113f4`). The
exact Xenia presenter and shader-source hashes are stored in
`integration/upscaling/overlay-manifest.json`.

Xenia was used as a source reference for the presenter flow and the
`guest_output_ffx_{fsr,cas}` shader source contracts. ReXGlue's own generated
D3D12/SPIR-V blobs remain the runtime inputs. No Xenia emulator library,
window, swap chain, GPU device, or guest clock implementation is linked into
the native port. The concrete effect is limited to enabling the already
available spatial presenter passes in an isolated SDK overlay and making the
temporal/runtime dependency explicit.

## Native verification

`tests/upscaling/native_presenter_test.cpp` includes the generated exact flow
body and runs headless checks for parser gates, FullHD flow sizes, EASU/RCAS and
CAS topology, DXBC container boundaries, resource chunks, and cbuffer constants.
The test also has a compile-time guard that fails if
`REX_HAS_FIDELITYFX_RUNTIME` is defined.

The verified run on 2026-09-13 produced:

```text
{"checks":211,"passed":true,"host_target":"1920x1080","temporal_runtime":false,"guest_clock_modified":false}
100% tests passed out of 1
```

The CMake object target compiled the actual overlay copies of
`src/ui/presenter.cpp` and `src/ui/d3d12/d3d12_presenter.cpp` with Clang 22.1.8.
No window, GPU device, game, ISO, or emulator process was launched during this
verification. A successful compile and a headless flow test establish the
presenter contract only; they do not establish visible image quality, monitor
refresh, game frame production, 120-Hz pacing, or unchanged gameplay/physics.
