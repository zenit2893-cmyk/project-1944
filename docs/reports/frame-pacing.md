# Native frame pacing boundary for the eventual 120-Hz path

This report records a host-only pacing component prepared for the Call of Duty
3 port. It is deliberately separate from `cod3-pc`, the ReXGlue guest clock,
the guest vblank worker, and the two previously observed timing candidates at
`0x82536DD0` and `0x825298D8`. The component is disabled by default and has not
been wired into the active game target. No game, emulator, or GUI was launched
for this work.

## The boundary that was identified

The native presentation boundary is the host swap-chain call, after the
renderer has submitted the command list and immediately before
`IDXGISwapChain::Present`. The scheduler belongs at that point:

```cpp
direct_queue->ExecuteCommandLists(1, &execute_command_list);
frame_pacing.BeforePresent(render_identity, host_qpc_clock);
HRESULT present_result = swap_chain->Present(0, present_flags);
```

The call to `BeforePresent` only waits on a host QPC deadline and records
telemetry. It never decides to skip the caller's `Present` call. A future
presenter adapter must keep the call on the same side of `ExecuteCommandLists`
and `Present`; it must not move the wait into a guest timing function.

The source-level path is:

| Layer | Evidence in the pinned source | Boundary meaning |
| --- | --- | --- |
| Guest video submission | `tools/Xenia-source/src/xenia/kernel/xboxkrnl/xboxkrnl_video.cc:466` begins `VdSwap_entry`; lines `538-543` write `PM4_XE_SWAP`, the front-buffer address, width and height into the guest ringbuffer | `VdSwap` publishes a guest frontbuffer/GPU swap packet. It is not the host window Present call and must not be used as the host 120-Hz deadline. |
| Guest output mailbox | `tools/Xenia-source/src/xenia/ui/presenter.cc:352` (`Presenter::RefreshGuestOutput`); lines `422-444` publish the latest mailbox image and may call `PaintAndPresent(false)` when the guest-output thread owns painting | This is the handoff from a completed guest output image to the native presenter. It is a useful render identity boundary, but the host wait still belongs at the final Present call. |
| UI presenter path | `tools/Xenia-source/src/xenia/ui/presenter.cc:215` (`PaintFromUIThread`); line `285` calls `PaintAndPresent(draw_ui)` | UI overlays can cause the same native Present path to run from the UI thread. The pacing state must follow the serialized host presenter, not the guest simulation thread. |
| Native GPU Present | `tools/Xenia-source/src/xenia/ui/d3d12/d3d12_presenter.cc:463` (`PaintAndPresentImpl`); lines `1068-1077` close/execute the command list and signal timelines; lines `1086-1089` call `swap_chain->Present(0, ...)` | This is the exact host gate. The future integration point is immediately before line 1086, after GPU submission and before DXGI Present. |

`nglPresent` is only a diagnostic string/reference in the exact title image at
`0x82018270` according to `docs/reports/title-analysis.md`; that address is not
treated as a proven function entry or as a host presentation callback. The
existing observations at `0x82536DD0` and `0x825298D8` remain useful for
measuring game timing, but they must continue to execute their original bodies
without a host-frame wait inserted into them. In particular, the outer-frame
candidate includes event processing and the normalization candidate carries
`fixedtime`, `timescale`, pause, and clamping behavior.

## Scheduler contract

`integration/frame-pacing/frame_pacing.h` and `.cpp` provide a small native
component with no ReXGlue or generated guest-code dependency. `Scheduler` has a
default configuration of `enabled=false`, so the disabled path returns before
calling QPC, waiting, or updating pacing telemetry. A host may opt in through
`Config{.enabled=true, .target_hz=120}` or by setting
`COD3_FRAME_PACING_120=1` (also `true`, `on`, or `120`) before constructing its
scheduler. The environment variable is an explicit opt-in; any missing or
unrecognized value leaves the scheduler disabled.

The production clock is `MakeSystemQpcClock()`. It obtains the Windows QPC
frequency once for a clock source and uses `QueryPerformanceCounter` for the
monotonic samples. The wait loop sleeps while the deadline is more than about
1 ms away, yields near the deadline, and uses a short `_mm_pause` tail. It does
not call `Clock::QueryGuestTickCount`, `MarkVblank`, `VdSwap`, or any generated
game function.

The period is represented as an integer quotient and remainder:

```text
base_ticks = qpc_frequency / target_hz
remainder  = qpc_frequency % target_hz
```

Every deadline adds `base_ticks`; the carry adds one extra QPC tick whenever
the accumulated remainder reaches `target_hz`. At a 1,000,000-Hz synthetic
clock, 120 Hz therefore produces intervals of 8,333, 8,333, and 8,334 ticks,
with the long-term sum retaining the exact `1/120`-second rate. A fixed 8-ms
integer sleep is not used.

The first host Present is immediate and arms the next deadline. Later calls
wait only until their native deadline. If a call arrives late, the scheduler
records its lateness and advances the rational schedule. It never runs missed
guest steps and never changes a guest timebase. After an unusually long
suspend/debugger break, catch-up is bounded at 4,096 periods and the scheduler
reanchors to the observed QPC; `catch_up_limited` and `reanchors` make that
condition visible.

The caller supplies a stable render identity when the renderer has one. Equal
consecutive identities increment `duplicate_frames`, but the scheduler still
permits both Presents. An unknown identity breaks the duplicate chain and is
counted as `unknown_frame_ids`. The identity must be a renderer scene/image
generation value; it must not be fabricated by incrementing a monitor tick or a
Present counter.

`Telemetry` exposes host observations only: gated calls, first and scheduled
on-time calls, waits, late calls, missed deadlines, duplicate render IDs, QPC
or wait failures, reanchors, wait totals, and maxima. These counters are not a
gameplay FPS result and do not certify visible 120 FPS, simulation invariance,
physics, input, audio, or monitor refresh behavior.

## Native validation

The test target uses a deterministic fake QPC source and does not link or
launch the game:

```powershell
Set-Location '<workspace>'
. .\scripts\toolchain-env.ps1 -Quiet
cmake -S integration/frame-pacing -B integration/frame-pacing/build -G Ninja `
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_COMPILER=clang++
cmake --build integration/frame-pacing/build --parallel 2
ctest --test-dir integration/frame-pacing/build --output-on-failure
```

The recorded local run passed `frame_pacing_native`. It checks disabled
passthrough, exact fractional carry, duplicate detection without dropping a
frame, late/missed-deadline accounting with recovery, unknown-ID chain reset,
and invalid-clock passthrough. These are native scheduler tests with a fake
clock; they do not establish that COD3 boots, renders, reaches `nglPresent`, or
produces 120 visible frames per second.

## Integration status

The scheduler is intentionally not added to `cod3-pc/CMakeLists.txt` and does
not alter the SDK, generated game C++, `VdSwap`, `0x82536DD0`,
`0x825298D8`, guest vblank, or guest timebase. A later integration change must
first obtain a real renderer-owned scene identity and then place one call at
the native `swap_chain->Present` boundary described above. Until a baseline
and a paired host capture exist, 120-Hz rendering and physics preservation
remain unverified.
