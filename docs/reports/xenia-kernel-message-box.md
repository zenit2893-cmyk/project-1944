# Xenia-derived XAM message-box adapter

This report records the narrow Xenia-to-ReXGlue borrowing used for the native
Call of Duty 3 port. It covers `XamShowMessageBoxUIEx` only. It does not enable
the Xenia executable, CPU JIT, Xenia GPU backend, or any generic success stub.

## Evidence and scope

The comparison uses the checked out commits below:

| Component | Revision | File |
| --- | --- | --- |
| Xenia Canary | `0e1307bd2e6bfeeff29635a6b823e72e61c97ce9` | `tools/Xenia-source/src/xenia/kernel/xam/xam_ui.cc` |
| ReXGlue SDK | `0c7b01a0ac0479801757507d80533f662fa0815d` | `tools/rexglue-source/src/kernel/xam/xam_ui.cpp` |
| CoD3 input image | SHA-256 `2944EEC7D1231AD6798B5F9F8ADF8855F5E489296B22EAB45B27A577CEE23692` | `game/cod3/default.xex` |

Xenia's `XamShowMessageBoxUIEx_entry` has the ten-argument Xbox 360 PPC
signature and forwards to its common `XamShowMessageBoxUi` implementation. The
eighth integer is reserved; the result pointer is argument nine and the
`XAM_OVERLAPPED` pointer is argument ten. ReXGlue's `HostToGuestFunction`
translates integer argument 8 and later from 8-byte slots beginning at
`r1 + 0x54`, so these two pointers arrive at `r1 + 0x54` and `r1 + 0x5c`.

The CoD3 function at guest address `0x823449D0` confirms that contract. Its
call at return address `0x82344A5C` sets `r3` through `r10` for the first eight
arguments, stores the result pointer at the first stack slot, and stores the
overlapped pointer at the second stack slot. It compares the return value with
`997` (`X_ERROR_IO_PENDING`) before waiting through the event created earlier
in the same function. This is why the adapter preserves the typed ABI instead
of accepting a zero-argument entry point.

## Isolated adapter

`integration/xenia-kernel/0001-forward-xam-message-box-ui-ex.patch` is a
`git apply --check`-clean patch against the pinned ReXGlue source. It replaces
the old zero-argument warning body with the typed entry point and forwards all
arguments to the existing ReXGlue `XamShowMessageBoxUI_entry`. The candidate
translation unit is kept at
`integration/xenia-kernel/candidate/src/kernel/xam/xam_ui.cpp` so it can be
compiled without changing the installed SDK, `cod3-pc`, or a game module.

The normal ReXGlue implementation remains the owner of dialog policy,
headless selection, result writes, deferred completion, event signalling,
completion routine dispatch, and the originating guest thread context. No
second implementation of those mechanisms is copied from Xenia.

The adapter source SHA-256 is
`5067F1ED5471F43E71A909ACA57141AA6235412FF364FABA6F60CF6923BC7CD6`; the
patch SHA-256 is
`29F17B9B5CB5FDE109339A3A890CDAF3758C73B3F906F4B07F05F73705E66B61`.

## Native contract test

`tests/xenia-kernel/Run.ps1` configures an isolated CMake build against the
installed ReXGlue SDK. The candidate translation unit is compiled as a
separate object target, while the probe links only the unmodified runtime and
calls the candidate adapter through a manually populated `PPCContext`.
`LoadXexImage` reads metadata only; the probe never launches the guest entry
point, opens a GUI, starts Xenia, or runs a CPU JIT.

`tests/xenia-kernel/message_box_probe.cpp` exercises the exact register and
stack positions used by the CoD3 call site. It checks synchronous headless
completion, big-endian result storage, preservation of nonvolatile state and
stack padding, `X_ERROR_IO_PENDING` for an overlapped call, deferred guest
event signalling, result/extended-error/length fields, originating thread
context, and the existing no-drawer fallback.

The latest run passed all 15 checks:

```text
RESULT 15/15 passed
100% tests passed out of 1
```

The machine-readable receipt is
`tests/xenia-kernel/results.json`; its `passed` field is `true`. The probe
uses the original XEX only as metadata input and leaves it unchanged. This
test establishes the adapter and kernel completion contract; it does not
claim a complete game boot, mission execution, graphics correctness, physics
stability, or 120 FPS.

## License provenance

The candidate retains the Xenia BSD 3-Clause attribution and points to
`tools/Xenia-source/LICENSE`. The workspace already carries the same license
text in `LICENSE`. The adapter contains only the small forwarding body; no
Xenia binary or emulator code is linked into the native port.
