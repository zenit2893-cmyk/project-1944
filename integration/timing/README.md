# Optional observation hooks for cod3-pc

This component records **candidate function calls**, with no FPS unlock and no
simulation replacement. It is disabled by default. It has not yet been validated
in Call of Duty 3 gameplay. The native tests call deliberately artificial reference
stubs and use the real SDK context layout and generated weak-alias arrangement.

The exact input SP XEX expected for these addresses has SHA-256
`2944eec7d1231ad6798b5f9f8adf8855f5e489296b22eab45b27a577cee23692`.
The logger records this **expected** identity, but does not verify the executable
loaded by the caller. The host must retain its executable identity gate.

| Address | Recorded event | Verified function contract |
| --- | --- | --- |
| `0x825298D8` | `candidate_ms_normalization` | ReXGlue raw `void(PPCContext&, uint8_t*)`; integer input/output in r3, existing fixedtime/timescale/clamp and pause paths |
| `0x82536DD0` | `candidate_outer_frame` | Same raw ABI; full original body executes, including event processing, timing, subsystem calls and epilogue; r3 at entry/exit is logged as an **untyped register**, not a defined frame return value |

The complete generated bodies were reviewed before choosing the raw ABI. Their
originals are `__imp__sub_825298D8` and `__imp__sub_82536DD0`. Strong hook symbols
override the weak generated names and call the corresponding `__imp__` once.
No argument marshaling, guest stack allocation, replacement time source, memory
patch or dispatcher lookup is used. Direct calls that explicitly bypass a weak
name and invoke an `__imp__` original are naturally outside hook coverage.

The wrapper reads r3/lr and forwards the same context reference and base pointer.
All original modifications to context, guest memory and host FP state are retained.
Observation code saves/restores host FPU environment, MXCSR, errno and Windows
LastError before returning to guest code. C++ exceptions are recorded as unwind
events and rethrown; crashes, SEH faults, longjmp and process termination may leave
an unmatched entry and/or a file without a footer.

Instrumentation necessarily adds execution time and a writer thread. It provides
observations of an instrumented run, not a proof of timing transparency or correct
gameplay. Measure overhead after the first working baseline exists.

## Host integration (root agent wires separately)

This folder is independent; it does not edit `cod3-pc`.

```cmake
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../integration/timing" timing)
cod3_enable_timing_hooks(cod3_pc)
```

After SDK setup and before any guest thread starts:

```cpp
#include "candidate_observer.h"
const auto observation_status =
    cod3::timing::ConfigureFromEnvironment(workspace_root);
// Status/output path may be reported once by the host at startup if desired.
```

After guest threads have joined:

```cpp
cod3::timing::Shutdown();
```

Configure and shutdown are lifecycle operations. Configure must not race guest
execution; it rejects a still-joinable writer or pending spans. Shutdown does not
wait for a guest function to finish. If calls are still pending, capture is marked
incomplete and late records are dropped. To obtain a complete footer, quiesce guest
threads before shutdown. Initialization or file errors leave forwarding intact.

Opt in for one process from PowerShell:

```powershell
$env:COD3_TIMING_TRACE = '1'
$env:COD3_TIMING_OUTPUT_DIR = 'analysis/timing/captures'
$env:COD3_TIMING_MAX_CALLS = '32768'  # optional, 1..65536
```

The output directory is resolved against the explicit workspace root. Canonical
paths outside that workspace are rejected. The logger creates a fresh
`cod3-candidate-<pid>-<qpc>-<suffix>.ndjson` using `CREATE_NEW`; existing files are
never replaced. Environment changes apply only before Configure; these are not hot
reload settings. With the opt-in unset, hooks forward without timestamps or I/O.

Logging has a fixed 4096-record queue. Producers use try-lock and never wait for
disk. A background thread writes batches of up to 128 records, with a 100 ms wake
timeout. Contention/full queues drop records and increment a counter. There is no
per-call allocation, JSON formatting or console logging on the guest thread.
Default limit: 32768 admitted calls, maximum 65536; hard file limit: 64 MiB.
At a limit, further observations stop while original calls continue. Limits,
missing calls, QPC failures and dropped records invalidate a complete capture.

## Trace meaning

Schema: `cod3-candidate-observation-v1`. It is deliberately separate from the
future authoritative `cod3-timing-v1` simulation/frame schema. Do **not** convert
candidate calls into sim ticks or render frames just to feed the older comparator.

Metadata declares `capture_source=native_hook_observation`,
`execution_kind_attested=false`, `loaded_executable_verified_by_logger=false`,
`gameplay_120fps_verified=false`, QPC frequency and limits. Native stub traces have
the same observation schema; their separate native test receipt identifies them.

Every admitted call emits `call_begin` and `call_end`, associated by `call_id`:

- `event` and `guest_address` identify the candidate function.
- `host_qpc` is the raw monotonic Windows QPC sample; use metadata frequency.
- `host_thread_id` is a host thread ID. IDs can be reused across runs.
- `r3_u64` and `r3_s32` are entry/exit register views. Outer-frame return semantics
  remain unknown; normalization values are candidate milliseconds, not physics dt.
- `guest_lr_u64` is the entry/exit PPC link register, preserved as raw evidence.
- `outer_call_id` associates normalization calls with the currently nested outer
  call on that host thread; zero means no observed enclosing outer call.
- `outcome` is `entered`, `returned` or `exception_unwind`.

Records from multiple threads can arrive out of QPC order. Associate pairs by ID,
and compute cadence within each event/thread after sorting timestamp samples.
Durations are inclusive, so an outer call can include nested observations.
Dropped records make interval distributions incomplete. The footer describes log
completeness only, always leaving `gameplay_120fps_verified=false`.

Read a trace with the standard-library Python helper:

```powershell
$env:PYTHONUTF8='1'
$timingPython = 'python'
& $timingPython '<workspace>\integration\timing\summarize_observations.py' `
  '<actual candidate trace path>' --output '<summary path>'
```

The summary labels rates as **entry calls per second**, never FPS or simulation
rate. Missing ends, exceptions and footer losses remain visible. A successful
parse is not a gameplay acceptance result.

## Native validation

```powershell
Set-Location '<workspace>'
. .\scripts\toolchain-env.ps1 -Quiet
cmake -S integration/timing -B integration/timing/build -G Ninja `
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang++
cmake --build integration/timing/build --parallel 2
ctest --test-dir integration/timing/build --output-on-failure
```

Seven native stub cases verify disabled/enabled forwarding, the generated weak
alias override, every byte of PPCContext, every byte of a 512-byte memory region,
ctx/base pointer identity, MXCSR/FP rounding and exception flags, errno/LastError,
nested calls, rethrown exceptions, eight simultaneous threads, record limits and
invalid-configuration passthrough. Receipts/traces are kept under
`integration/timing/build/test-artifacts/native-stubs-<pid>` and are explicitly
stub tests. The stress test permits deliberate queue-contention loss and verifies
that loss is exposed, never treated as a complete capture.
