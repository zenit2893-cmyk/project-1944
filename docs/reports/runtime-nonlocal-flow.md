# Call of Duty 3 nonlocal control flow

The previously reproduced XEX allocation defect is a separate bug. Its corrected runtime preserved allocations but did not eliminate the Saint-Lo access violation. Native diagnostics show `sub_89099818` returning with a different guest stack pointer and zeroed `r30/r31`; the original values remain intact in its old stack save slots. Resetting those registers would conceal the control-flow failure.

The annotations `c:\cod\code\script\_load.bro`, line 161, `_introscreen::main` belong to a script-dispatch path. They do not establish an assertion or fatal game error. The closure getter at `0x8909E208` returns the field at closure+8, while the closure also contains a generated function pointer. The exact source-level scheduler semantics require the live engine-interface trace.

**Confirmed guest CRT pair.**

| Operation | Guest address | Evidence |
| --- | --- | --- |
| setjmp | `0x82351CC0` | Saves `f14..f31`, `r13..r31`, guest SP at buffer+144, CR at +304, LR at +308, zeroes flag +312 and returns 0. |
| longjmp | `0x8234EEC0` | Reads the matching layout, converts return value 0 to 1, restores LR/SP/nonvolatile registers and executes `blr`. |

Ordinary translated C++ for the second routine restores the guest registers and then returns to its immediate native caller. `blr` here needs to resume the older saved invocation; an ordinary C++ return does not do that. This makes the saved guest context inconsistent with the still-active native call frames.

The supported ReXGlue configuration for the pinned executable is:

```toml
[entrypoint]
setjmp_address = 0x82351CC0
longjmp_address = 0x8234EEC0
```

The settings belong alongside the entrypoint's file/output settings, before `[entrypoint.functions]`. They are not kernel stubs or guest binary patches. `src/codegen/builders/context.cpp` recognizes direct calls to these addresses and emits native `setjmp` at the surviving caller's call site. It snapshots `PPCContext` there and restores it on the nonzero return. Calls to the matching longjmp routine emit `ppc_longjmp` instead of executing the register-restoring routine as an ordinary returning C++ function.

An isolated strict codegen pass with those settings succeeded. It emitted **7 native setjmp sites and 8 native longjmp sites**, all in the main image. The setjmp callers are `823217D8`, `82321C58`, `824A6150`, `82309A50`, `82309720`, `8230A900`, `8230A708`; longjmp callers are `82306AD8`, `82306C70`, `824A55E8`, `824A56B8`, `8231CB58`, `824A53D8`, `824AB570`, `8231CBA8`. `82306C70` is a tail-call wrapper and is also handled by the emitter. No matching direct CRT calls were found in the Saint-Lo image. Searching the captured main image for stored absolute addresses found no setjmp address and one longjmp address in `.pdata`; this is a bounded static check, not proof that every possible indirect call is absent.

**Cross-DLL native test passed.** `integration/nonlocal-flow/Run.ps1` builds a main executable and a separate guest-frame DLL with Clang 22.1.8, MSVC ABI, RelWithDebInfo. It uses the actual generated SDK header and the same context-save/native-setjmp/context-restore sequence emitted by codegen. The main image enters a DLL, that DLL changes guest SP and nonvolatile registers, and a callback in the main image executes longjmp. For values 0, 1 and 7, execution resumes at the original call site with values 1, 1 and 7; intermediate returns are skipped, SP/r30/r31 are restored, and the DLL's test RAII cleanup runs. No game entry is executed by this test. Receipts and generated call-site inventory are in `integration/nonlocal-flow/results.json`.

The generated header's jump-buffer map is `static thread_local` storage in an inline function. The probe confirms that the executable and DLL have **separate maps**. The tested game path can cross DLL frames because both the native setjmp and the eventual native longjmp call live in the main image. If a future module directly owns one endpoint while another image owns the other, a shared per-thread registry must be provided through one native component, or the endpoints must otherwise use the same storage. Simply compiling the current header into both images will not share that map.

Do not implement setjmp as a normal hook function which calls native setjmp and then returns: that saves a host frame whose lifetime has already ended when longjmp needs it. Also do not replace longjmp with success, reset SP/registers on return, or suppress the script invocation. Microsoft documents both the required lifetime of the setjmp caller and the Windows-specific stack-unwind behavior of longjmp. [Microsoft setjmp documentation](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/setjmp?view=msvc-170), [Microsoft longjmp documentation](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/longjmp?view=msvc-170).

The configuration and native test establish correct support for this identified CRT mechanism. They do not prove that every custom coroutine/context switch, guest exception path or scheduler transition in the game has been reconstructed. In particular, `0x8235EA8C` is a separate CONTEXT restoration routine and is not configured as this longjmp address. Gameplay and the specific Saint-Lo transition still need a live run with the corrected codegen settings.
