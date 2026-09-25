# Native host frame pacing

This folder contains the disabled-by-default QPC deadline scheduler reserved
for a later native presenter integration. It gates the host
`IDXGISwapChain::Present` boundary only; it has no interface to ReXGlue guest
time, vblank, generated code, simulation, or physics.

The public API is `frame_pacing.h`:

```cpp
cod3::frame_pacing::Scheduler pacing({.enabled = true, .target_hz = 120});
const auto clock = cod3::frame_pacing::MakeSystemQpcClock();

// Immediately before the native swap-chain Present call:
const auto gate = pacing.BeforePresent(render_identity, clock);
HRESULT result = swap_chain->Present(0, present_flags);
```

`BeforePresent` may wait until the QPC deadline, but never suppresses the
caller’s Present. Pass a renderer-owned scene/image generation as
`FrameIdentity::Render(id)` to observe repeated images; pass `Unknown()` when
the renderer cannot provide one. The scheduler keeps a fractional QPC carry so
`frequency / 120` is not truncated to a fixed 8-ms interval.

Build the deterministic native tests from the workspace root:

```powershell
. .\scripts\toolchain-env.ps1 -Quiet
cmake -S integration/frame-pacing -B integration/frame-pacing/build -G Ninja `
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_COMPILER=clang++
cmake --build integration/frame-pacing/build --parallel 2
ctest --test-dir integration/frame-pacing/build --output-on-failure
```

The exact VdSwap, guest timing candidate, `nglPresent` evidence, and the
eventual presenter insertion point are recorded in
`docs/reports/frame-pacing.md` and the machine-readable validation receipt
`docs/reports/frame-pacing-validation.json`.
