# Xenia/ReXGlue thread and wait contract

This report is the bounded native stability slice for the Call of Duty 3
native port. It compares the pinned source trees and checks the installed
ReXGlue primitives in a headless Windows x64 process. It does not load an XEX,
execute a guest entry point, use the Xenia emulator or CPU JIT, change the
simulation clock, or claim gameplay or 120 FPS validation.

The source revisions are the supplied Xenia Canary tree at
`tools/Xenia-source` (`0e1307bd2e6bfeeff29635a6b823e72e61c97ce9`) and the
matching ReXGlue source tree at `tools/rexglue-source`
(`0c7b01a0ac0479801757507d80533f662fa0815d`). Both trees are retained as
reference material. The probe links only the installed `win-amd64` ReXGlue
runtime.

## Native checks

Run the isolated contract probe from `<workspace>`:

```powershell
. .\scripts\toolchain-env.ps1 -Quiet
& .\integration\xenia-threads\Run-Tests.ps1
```

The script creates its build directory below `integration/xenia-threads` and
writes the machine-readable receipt to
`integration/xenia-threads/test-results.json`. The test covers:

* suspended thread creation, resume, thread-handle signaling and join;
* manual-reset and auto-reset event wakeups;
* `WaitAny`, `WaitAll`, semaphore permit consumption and over-limit release;
* a queued user APC held during a non-alertable wait and delivered by an
  alertable sleep on the target thread;
* one-shot waitable timer callback affinity, signaling and cancellation before
  the due time;
* repeating timer-queue disarm waiting for an in-flight callback;
* one root fiber, a parked child fiber and two continuation resumes.

The run on this PC passed **48/48** checks in 0.88 seconds. The receipt was
generated at `2026-09-13T13:21:19.6217396Z` with probe SHA-256
`3363FF617388AFDD0A8750114970C6FF592FB2CD2AD75CF7E7B366A86797C023` and
installed `rexruntime.dll` SHA-256
`D06762F2D58E6014707FC2141CC383F65EA04DB71D7BFFD47FD257BA62F3E1F2`.
The first build attempt also exposed that the installed SDK does not export
the private `Fiber::tls_current_` storage needed by the inline `Fiber::Current`
helper; the probe therefore checks root ownership through the documented
single-conversion failure and continuation behavior without reaching into
private runtime storage. No SDK file was changed.

These are host primitive contracts. They do not establish that every CoD3
guest wait object, XAM overlapped request or custom coroutine uses the same
path.

## Comparison and implications

| Area | Xenia reference | ReXGlue reference | Port consequence |
| --- | --- | --- | --- |
| Guest child CPU selection | `src/xenia/kernel/xthread.cc:152-168` keeps a child without an explicit processor mask on its parent's active CPU. | `src/system/xthread.cpp:186-203` increments a process-wide `next_cpu` when the mask is zero. | Even with host affinity ignored, the guest `current_cpu` value and any CPU keyed title bookkeeping can differ. Preserve the parent CPU semantics or gate the change behind a measured title requirement. |
| Root fiber ownership | Xenia's Windows reentry path uses a thread-local `setjmp` buffer in `src/xenia/kernel/xthread.cc:572-655`; it does not own the ReXGlue fiber root. | `src/system/xthread.cpp:641-649` converts the executing host thread once and stores `main_fiber_`; `src/core/fiber_win32.cpp:23-33` binds the result in TLS. | Native coroutine code must borrow this root and switch back to it. A second conversion on the same host thread returns null. `Fiber::Destroy` for a thread fiber calls `ConvertFiberToThread`, so the owner must destroy it on the owning host thread; cross-thread `XThread` object destruction needs an explicit owner handoff. |
| Wait result and APC | Xenia maps Windows wait results in `src/xenia/base/threading_win.cc:211-301`; alertable waits report `WAIT_IO_COMPLETION`. `xeProcessUserApcs` runs after an alertable wait in `src/xenia/kernel/xboxkrnl/xboxkrnl_threading.cc:1002-1009`. | ReXGlue maps the same results in `src/core/threading_win.cpp:142-205`; `XObject::Wait` then returns `X_STATUS_USER_APC` and the kernel wrapper calls `DeliverAPCs` (`src/system/xobject.cpp:203-232`, `src/kernel/xboxkrnl/xboxkrnl_threading.cpp:820-836`). | The wakeup APC is only a hint. Guest APC bodies must run on alertable wait/delay paths and on the target guest thread. Calling `DeliverAPCs` from a timer queue thread or non-alertable wait would change the contract. |
| Cross-thread APC queueing | Xenia `xeNtQueueApcThread` allocates guest APC state and calls `xeKeInsertQueueApc` with the caller context, then queues a no-op host APC (`src/xenia/kernel/xboxkrnl/xboxkrnl_threading.cc:1352-1380`). | ReXGlue `XThread::EnqueueApc` uses `runtime::current_ppc_context()` for the queue lock and follows the same no-op wakeup (`src/system/xthread.cpp:689-718`). | The ReXGlue caller-context choice avoids using the target's PPC context while another thread is queuing. Keep this property when integrating native callbacks. |
| Event query | Xenia `XEvent::Query` calls the native event query operation (`src/xenia/kernel/xevent.cc:77-82`), so reading state does not consume an auto-reset signal. | ReXGlue `XEvent::Query` does a zero-time `Wait` and then calls `Set` to restore state (`src/system/xevent.cpp:59-74`). | A concurrent waiter can observe a signal stolen and reissued to a different waiter. Do not use `Query` as a synchronization test for an auto-reset event until a non-consuming query is available. |
| Timer callback state | Xenia serializes `XTimer::SetTimer` and `Cancel` with `timer_lock_` (`src/xenia/kernel/xtimer.cc:39-101`) and captures callback values into the waitable-timer callback. | ReXGlue `XTimer::SetTimer` writes `callback_thread_`, `callback_routine_` and `callback_routine_arg_` without a lock (`src/system/xtimer.cpp:40-88`); the callback captures `this` and rereads those fields at fire time. | Concurrent reset/cancel can race with a pending callback and can target the wrong guest thread or routine. This is a concrete SDK integration blocker for timer-heavy code; it needs an SDK-side lock/capture fix before relying on concurrent timer mutation. |
| Timer queue disarm | Xenia's queue uses `std::thread` plus an atomic shutdown flag and spins while a callback is active (`src/xenia/base/threading_timer_queue.cc:63-73`, `181-213`). | ReXGlue uses `std::jthread` stop tokens and waits with `atomic::wait`; callback completion calls `notify_all` (`src/core/timer_queue.cpp:46-56`, `157-188`). | The ReXGlue queue has a bounded join and callback-drain path. The native test checks the important lifetime guarantee: after disarm returns, no later callback accesses the destroyed owner. |
| Timer timebase | Both Windows timer backends use waitable timers; Xenia's `XTimer` scales periods and converts guest absolute/relative times (`src/xenia/kernel/xtimer.cc:39-89`). | ReXGlue preserves the conversion and calls `chrono::Clock::ScaleGuestDurationMillis` (`src/system/xtimer.cpp:40-88`). | This slice leaves the guest clock untouched. A 120 Hz render target must not be implemented by changing this timer or wait scale. |

## Current conclusion

The native probe is the first check for the host primitives and root-fiber
ownership used by the port. A passing receipt supports the basic ReXGlue
Windows contract on this PC; it does not close the three integration risks in
the table.

The highest priority follow-up is the ReXGlue `XTimer` synchronization/capture
issue, followed by title-specific validation of the zero-affinity CPU value and
an owner-thread destruction path for `main_fiber_`. The `XEvent::Query`
behavior should be treated as a semantic limitation whenever an auto-reset
event has multiple waiters.

The earlier Call of Duty 3 run still ends in a guest access violation during
Saint-Lo initialization. Its log reports a read of guest `0x00000010` on
thread `0xF8000028`; no thread/event/timer failure was logged before that
fault. This report therefore does not attribute that crash to the native wait
slice.
