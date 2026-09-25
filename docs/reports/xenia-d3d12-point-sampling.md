# Xenia D3D12 point-sampling adaptation

Recorded 2026-09-13. This report covers one narrowly scoped renderer stability
change staged for the ReXGlue source tree. It does not claim that the native
Call of Duty 3 port is playable or that 120 FPS has been validated.

## Source comparison

The supplied Xenia source checkout is pinned to
`0e1307bd2e6bfeeff29635a6b823e72e61c97ce9`. That history contains upstream
commit `197929d967f587502256fd52c0c5121781fd0e47`, titled
"[D3D12] Fall back to point sampling for non-filterable formats". The commit
changes only Xenia's D3D12 texture cache implementation and its header.

The matching ReXGlue source checkout is pinned to
`0c7b01a0ac0479801757507d80533f662fa0815d`. Its D3D12 texture cache retains
the corresponding `Disable filtering for texture formats not supporting it`
TODO and has the same 64-entry Xenos `host_formats_` table, but no D3D12
filterability masks. The Xenia code was adapted to ReXGlue names and include
layout; no Xenia command processor, shader translator, renderer, JIT, or game
source was copied.

The source attribution and BSD-3-Clause terms are retained in
`integration/xenia-graphics/XENIA-LICENSE`. The exact upstream commit is kept
in `integration/xenia-graphics/upstream-197929d.patch`, and the generated
overlay hashes and source pins are recorded in
`integration/xenia-graphics/point-sampling-provenance.json`.

## Adapted behavior

`D3D12TextureCache::Initialize` queries
`D3D12_FEATURE_DATA_FORMAT_SUPPORT` for each non-unknown unsigned and signed
DXGI view in `host_formats_`. A format bit is marked usable only when
`CheckFeatureSupport` succeeds and reports
`D3D12_FORMAT_SUPPORT1_SHADER_SAMPLE`.

`GetSamplerParameters` checks those masks only when the guest requests linear
mag/min/mip sampling or anisotropic filtering. If the fetch constant is
invalid, a required signedness view is not sample-capable, or the capability
query did not succeed, it clears all linear flags and disables anisotropy. The
existing point-sampling path remains unchanged. For mixed signedness swizzles,
both required views must be marked sample-capable, matching the upstream
fallback's conservative behavior.

The mask is 64 bits because `xenos::TextureFormat` occupies values 0 through
63 and `host_formats_` has 64 entries. The fallback does not add a host format,
decompress a texture, repair an unsupported resource, change render-target
creation, alter shader translation, or change the guest clock and simulation.
An unsupported resource can therefore still fail at texture creation; this
patch only prevents a sampler descriptor from requesting filtering for a view
whose host capability was not established.

## Validation

The artifact test is read-only and checks the two source pins, upstream file
set, exact base and overlay SHA-256 values, patch file scope, retained license,
and the fallback markers:

```powershell
$python = 'python'
& $python tests/xenia-graphics/test_point_sampling_patch.py
```

Recorded result:

```text
xenia-d3d12-point-sampling: PASS
  source pins: rexglue=0c7b01a0ac0479801757507d80533f662fa0815d, xenia=0e1307bd2e6bfeeff29635a6b823e72e61c97ce9
  overlay files: 2; patch sha256=66e47102b79801e6cb35b96d6228bfa400acef71b3deebe25ebacd7b55d333d3
```

The real adapted translation unit was then compiled with the bundled Clang,
MSVC headers, Windows SDK, and ReXGlue source include paths:

```powershell
. .\scripts\toolchain-env.ps1 -Quiet
& .\tools\ninja\ninja.exe -C integration/xenia-graphics/build -v graphics_patch_compile
```

The compile completed successfully. It emitted four existing upstream
`-Wnontrivial-memcall` warnings from `rex/graphics/pipeline/texture/cache.h`
for `memcpy`/`memset` on packed cache structures; the overlay introduced no
diagnostic. The target is an OBJECT compile check and does not link a new
runtime or load a GPU plugin.

Existing native-run logs show that this host reached an NVIDIA GeForce RTX
5070 and initialized a D3D12 device, including resource binding tier 3,
rasterizer-ordered views, tier-4 tiled resources, and unaligned block
compressed texture support (`logs/cod3-pc-run-20260905-100006.log`, lines
1–10). Those logs do not contain per-format `CheckFeatureSupport` results and
were produced before this overlay was runtime-integrated, so they are hardware
and baseline initialization evidence only. No game, emulator, or GUI launch
was performed for this patch validation.

## RTX 5070 D3D12 applicability and limits

The change is suitable for an RTX 5070 D3D12 path at the API level: it uses
core D3D12 format capability queries and has no NVIDIA-specific dependency.
The runtime decision is per host view. If the RTX 5070 driver reports shader
sampling for a mapped view, guest filtering is preserved; if it does not, the
sampler falls back to point filtering. If a query fails, the safe result is
also point filtering.

The exact scope is limited to the 64 Xenos texture format slots and the
unsigned/signed views exposed by the existing ReXGlue `host_formats_` table.
It provides no guarantee that every COD3 texture format is supported, no
fallback for an unknown or uncreatable resource, no proof of visual parity,
and no proof of 1920×1080 output or 120 FPS. Those claims require a later
runtime-integrated build, per-format capability receipt, frame capture, and
gameplay/physics validation.
