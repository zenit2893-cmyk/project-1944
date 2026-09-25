# CoD3 coroutine runtime bridge

This report records the isolated production bridge work for the native PC
port. It is scoped to the scheduler continuation problem in the supplied
retail XEX; it does not claim that the game has been launched or that scene,
rendering, timing, physics, or 120 FPS behavior has been validated.

The implementation is in
[`integration/coroutines/cod3_coroutines.cpp`](../../integration/coroutines/cod3_coroutines.cpp)
and its public contract is in
[`integration/coroutines/cod3_coroutines.h`](../../integration/coroutines/cod3_coroutines.h).
It keeps the original guest scheduler, wait allocation/list updates, 400-byte
capture frame, stack-copy representation, register loads, and node destructor
in generated code. Native fibers only retain the translated C++ call frames
that the guest `blr` cannot reconstruct.

The bridge now uses `rex::thread::Fiber` for every native switch. The game hook
passes `XThread::main_fiber()` into `ResumeScope`, so the root created and
owned by ReXGlue is borrowed and its current-fiber TLS marker is updated by the
same SDK path as the rest of the runtime. A thread with no SDK root may use the
bridge-owned conversion path; `ReleaseThread()` destroys that root only after
all parked tasks have been cooperatively cancelled. A raw pre-existing fiber
without an SDK owner handle is rejected because it cannot preserve ReXGlue's
fiber ownership contract safely.

Before each child switch, the bridge snapshots the scheduler's native FP
policy. On return it combines that policy with the guest-owned rounding and
flush bits currently carried by `PPCContext`. This preserves child changes to
the guest FPSCR while preventing child MXCSR exception status or host policy
from leaking into a plain ReXGlue root. The bridge never restores CR, XER,
VMX, or an invented full PPC context after the original guest restore stream;
the verified asymmetry remains intact.

The verified transfer boundaries remain:

* scheduler entry `824A6150` and the exact guest node;
* first closure dispatch `823C0B98` with caller LR `824A62A8`;
* all 45 timed, integer, and event capture entries from the 15 mission images;
* the post-restore `824A6480` hook;
* scheduler longjmp owner `829EB1C0`;
* node destruction `824A5D70` and main-image `XexUnloadImage` cleanup.

The generated capture wrappers continue to be prepared only from
[`analysis/cod3-allmodule-coroutine-sites.json`](../../analysis/cod3-allmodule-coroutine-sites.json).
`Prepare.ps1` verifies the pinned image hashes and complete original-body
comparisons before writing wrappers, and does not modify any game image or
installed SDK file.

Validation command:

```powershell
.\integration\coroutines\Run-Tests.ps1
```

The current isolated run passes all six checks: 32 independent reference
states survive two yield/resume cycles, normal and nonlocal completion are
distinguished, parked cancellation unwinds before module unload, unsupported
foreign-buffer jumps are rejected, a bridge-owned root is released, and an SDK
borrowed root survives the same cases. The fixtures also check native locals,
shared `PPCContext` identity, thread-local state, raw FPR/VMX/CR/XER payloads,
guest FP bits, and scheduler host FP policy. These are synthetic guest bodies
and opcode-derived states; they are not a live gameplay result.

The parent application target still owns integration into the final generated
build. Its CMake wiring should add this directory and call
`cod3_enable_coroutines(cod3_pc "${CMAKE_CURRENT_SOURCE_DIR}/generated/default")`
after the host and all 15 mission targets exist. No CMake file under
`cod3-pc` is changed by this bridge work.
