# XenonRecomp → ReXGlue timebase contract

The isolated adapter and its native checks are complete. A selected
XenonRecomp-generated `mftb` expression can now be compiled through
`rex::chrono::Clock::QueryGuestTickCount()`, which keeps the Xbox 360 guest
unit (50,000,000 ticks/s) and ReXGlue's synchronization rules. The adapter does
not set the guest frequency, change the time scalar, touch vblank, or unlock
120 FPS. It is not attached to the active `cod3-pc` generated sources.

## Evidence that was reconciled

The pinned XenonRecomp checkout is `ddd128bcca99fe8bfbb99bea583c972351fa6ace`.
Its `XenonRecomp/recompiler.cpp:1262-1263` emits the host-counter expression
`__rdtsc()` for PPC `mftb`. The exact CoD3 TU0 output contains that expression
in two timer functions:

| Guest function | XenonRecomp output | Timer behavior relevant to the bridge |
| --- | --- | --- |
| `0x82345740` (`sub_82345740`) | `analysis/title-xenon-generated/ppc_recomp.37.cpp:40694-40714` | Reads `mftb`, writes the 64-bit value through the caller pointer, and returns `1`. |
| `0x822C2410` (`sub_822C2410`) | `analysis/title-xenon-generated/ppc_recomp.31.cpp:12765-12811` | Samples `mftb` before and after event work, then compares the delta with a value derived from `KeQueryPerformanceFrequency`. |

The pinned ReXGlue checkout is `0c7b01a0ac0479801757507d80533f662fa0815d`.
Runtime initialization sets the guest frequency to 50,000,000 and the normal
scalar to `1.0` in `src/system/runtime.cpp:107-110`. The generated ReXGlue
template maps `mftb` to `rex::chrono::Clock::QueryGuestTickCount()` at
`resources/templates/codegen/pch_h.inja:263`. On Windows, the pinned platform
clock obtains host ticks with QPC in `src/core/clock_win.cpp:18-28`; the
conversion and accumulation are performed by `src/core/clock.cpp:30-96` and
`:145-160`.

Xenia's pinned source (`0e1307bd2e6bfeeff29635a6b823e72e61c97ce`) establishes
the same guest contract in `src/xenia/emulator.cc:209-215`. Its clock updates
guest ticks by accumulating the floored rational value
`host_delta * guest_frequency / host_frequency` in
`src/xenia/base/clock.cc:73-100`. Xenia also has an optional raw host clock
source (`clock_source_raw`), but that is an emulator host-source option. It is
not part of this adapter and cannot be used as the guest `mftb` value.

Using a CPU TSC value directly in `sub_822C2410` would compare CPU-frequency
units against `KeQueryPerformanceFrequency`'s 50 MHz guest units. That is the
unit mismatch this bridge closes.

## Adapter boundary

`integration/timebase/rexglue_xenon_timebase.cpp` contains three operations:

* `ReadGuestClockContract()` reads the configured ReXGlue frequency and scalar
  without changing either value. `GuestClockContract::IsCanonical()` is a
  diagnostic gate for the expected 50 MHz / `1.0` configuration.
* `QueryReXGlueGuestTicks()` delegates to the SDK's guest clock. It does not
  call QPC, read a TSC register, derive a value from Present, or use vblank.
* `QuerySelectedXenonMftb()` is the only function intended for the selected
  XenonRecomp include seam and delegates to the previous operation.

The seam is lexical and opt-in. A future isolated Xenon TU may scope its
generated mftb token around one include, then immediately undefine it, for
example:

```cpp
#define __rdtsc() ::cod3::timebase::QuerySelectedXenonMftb()
#include "selected_xenon_generated.inl"
#undef __rdtsc
```

The macro must not enter a project-wide PCH, the ReXGlue codegen template, or
the active `cod3-pc/generated` tree. The current two branch thunks in
`integration/xenon` contain no `mftb` and therefore do not need this bridge.

`integration/timebase/time_conversion.h` is an offline mathematical oracle for
tests. It models the Xenia/ReXGlue rational conversion with exact 32-bit-limb
arithmetic and saturates only when a test asks for an unrepresentable `uint64`
result. It is not a second runtime clock and is not used to drive frames or
simulation.

## Native checks

The standalone test project is `tests/timebase`. With the verified toolchain:

```powershell
Set-Location '<workspace>'
. .\scripts\toolchain-env.ps1 -Quiet
cmake -S tests/timebase -B tests/timebase/build -G Ninja `
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER="$env:CXX"
cmake --build tests/timebase/build --parallel 2
ctest --test-dir tests/timebase/build --output-on-failure
```

The native test passed on 2026-09-13 with Clang 22.1.8. It checks:

* the 50 MHz guest ratio against an independent integer reference over four
  host frequencies and thirteen deltas;
* equal per-update results for Xenia and ReXGlue models, including a backwards
  host sample, which must not move guest time backwards;
* guest tick conversion to milliseconds and nanoseconds, including saturation
  at the `uint64` boundary;
* the selected Xenon mftb include expression and the read-only ReXGlue contract;
* source-level absence of a direct host TSC token in the adapter files.

Result: `2/2` CTest tests passed (`timebase_native_contract` and
`timebase_adapter_source_no_host_tsc`). The test process does not launch the
game or an emulator and does not call any clock setter.

The host QPC distinction remains explicit. QPC is suitable for observing a
host interval in a diagnostic trace and for the independent conversion oracle.
It is not a guest simulation timestamp. The adapter returns the guest clock
value owned by ReXGlue; no observation timestamp is converted into a frame,
physics step, or 120 Hz schedule.

## Scope and next integration gate

This change is an adapter plus differential evidence only. It does not prove
that Call of Duty 3 has a particular simulation rate, does not change the
guest vblank source, and does not establish 120 FPS. A future selected
Xenon-generated function may use the seam only after its complete context,
memory, import, exception, and `KeQueryPerformanceFrequency` contracts are
independently checked. The active ReXGlue-generated CoD3 files remain
untouched.
