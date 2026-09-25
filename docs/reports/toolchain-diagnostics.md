# Process-specific native diagnostics

`scripts/toolchain-diagnostics.ps1` reads only Windows Application Error event 1000 records matching the exact executable path and launch time. A supplied native runtime receipt additionally filters by the process ID. It does not launch the game, install a debugger, change WER/registry configuration, enable a global dump policy, or read unrelated application events.

```powershell
& '<workspace>\scripts\toolchain-diagnostics.ps1' -Mode Inventory
& '<workspace>\scripts\toolchain-diagnostics.ps1' -Mode Events `
  -ReceiptPath '<workspace>\analysis\cod3-pc-runtime-probe-20260905-081952.json'
```

Outputs contain exception code, module path, module-relative fault offset, process ID, timestamp, and the exact matching XML record. The helper runs the bundled `llvm-symbolizer` against the local module/PDB; it has a 30-second timeout and disables debuginfod network lookup. A single address can also be resolved explicitly:

```powershell
& '<workspace>\scripts\toolchain-diagnostics.ps1' -Mode SymbolizeOffset `
  -ModulePath '<workspace>\cod3-pc\out\build\win-amd64-relwithdebinfo\cod3_pc.exe' `
  -RelativeOffset '0x1234'
```

Use the actual module-relative offset from a diagnostic record; `0x1234` above is only a syntax example. Preserve the EXE/DLL and matching PDB from the failing build. Event 1000 supplies a fault location, not a full call stack. Missing events do not establish a clean exit, and missing symbols are reported rather than replaced with guesses.

The helper was exercised on the first real native launch, PID 15348, start `2026-09-05T08:19:52.8859890Z`. It found event 2008 at `2026-09-05T08:19:57.1679120Z`: exception `C0000409`, module `ucrtbase.dll`, offset `0xA527E`. The local Windows PDB is absent, so no function name or stack is claimed. The root's runtime log separately identifies an explicit ReXGlue fatal error for unknown guest function `822C27F8`; the Windows event alone does not establish that cause. Evidence: `toolchain-diagnostics-first-run/events.json` and `event-2008.xml`.

The bundled LLVM archive contains `llvm-symbolizer`, `llvm-pdbutil`, `llvm-readobj`, and `llvm-objdump`, but no LLDB. CDB/WinDbg/ProcDump were not present. A download of the official WinDbg bundle was stopped at the root's request after the actionable guest-function failure was identified. No debugger or custom debugger runner was installed.

For a future opaque native failure, a process-specific debugger/minidump capture is the next step. Microsoft recommends calling [MiniDumpWriteDump from a separate process](https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/nf-minidumpapiset-minidumpwritedump); full stacks need the dump and matching symbols. [Microsoft's dump documentation](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/user-mode-dump-files) describes CDB/WinDbg workflows without requiring a permanent postmortem policy. Such capture is not implemented or validated by this helper.
