# Local Windows C++ toolchain

Installed on 2026-09-05 inside `<workspace>`. No global PATH changes, Visual Studio installation, reboot, or administrator elevation were required.

| Component | Version | Workspace path |
| --- | --- | --- |
| LLVM/Clang | 22.1.8, x86_64-pc-windows-msvc | `tools/toolchain/llvm/bin` |
| MSVC tools | VC Tools 14.44.35207; cl 19.44.35228.0 | `tools/toolchain/msvc/VC/Tools/MSVC/14.44.35207` |
| Windows SDK | 10.0.26100.0 | `tools/toolchain/msvc/Windows Kits/10` |
| CMake | 4.4.3 | `tools/cmake/bin` |
| Ninja | 1.13.2 | `tools/ninja` |
| ReXGlue binary SDK | 0.10.0.5-dev.g0c7b01a | `win-amd64` |

Activate from any PowerShell working directory:

```powershell
. '<workspace>\scripts\toolchain-env.ps1'
clang++ --version
clang-cl --version
cmake --version
ninja --version
```

The wrapper sets the current process's `PATH`, `INCLUDE`, `LIB`, `LIBPATH`, MSVC/Windows SDK variables, `CC=clang`, `CXX=clang++`, and `REXSDK`. Both GNU and clang-cl frontends target the MSVC ABI. Close the shell to discard these process-local changes. The extraction includes the development CRT DLLs in its tool directories; no DLLs were copied to System32.

Two actual C++23 executables were configured, compiled, linked against the supplied ReXGlue SDK, and run successfully: one using clang++ and one using clang-cl. The smoke test includes Win32 QueryPerformanceCounter/QueryPerformanceFrequency, `std::expected`, compiled fmt calls, and a ReXGlue `Clock::QueryHostTickFrequency()` call through the linked runtime DLL. Both executions returned 0 and reported Win32/ReXGlue host clock frequencies of 10,000,000 Hz. This verifies the local native toolchain and SDK ABI integration; it does not test the game's renderer, input, physics, timing, or frame rate.

Repeat the smoke check:

```powershell
& '<workspace>\scripts\toolchain-smoke.ps1'
```

Evidence is in `toolchain-status.json` and `toolchain-smoke-{gnu,cl}-{configure,build,run}.log` next to this document. Smoke sources and executables are under `tools/toolchain/smoke`.

The LLVM, CMake, and Ninja archives came from their projects' official GitHub releases. Their SHA256 hashes matched the release API digests before extraction. Downloads are retained in `tools/toolchain/downloads`; URLs and hashes are recorded in `toolchain-status.json`.

Microsoft compiler/SDK packages came directly from `download.visualstudio.microsoft.com`, using the VS 2022 release channel and the open source PortableMSVC extractor. The extractor source is retained under `tools/toolchain-bootstrap` at commit `76d1149870991c94ae9fda29c19507db253ca5a9`; its isolated Python environment is under `tools/toolchain/bootstrap-python`. `bootstrap-requirements.txt` records Python dependency versions. The installer did not register the toolchain in HKCU.

The VS channel declared SHA256 `bd98dd01efa4195cb1c11030da63b9e4a3bcec7bc406799a9db80339d6dabd79` for its manifest URL, but Microsoft served bytes hashing to `3891c3018a07338b3880cbb28088bb22ef7762eb9206523655b2e3972b9d527e`. Independent Python and PowerShell HTTPS downloads returned the same served hash. This discrepancy is recorded, not represented as a successful channel-manifest hash check. Compiler and SDK payload hashes were individually verified against the served official manifest. The complete URLs, hashes, extracted file list, versions, and both manifest hashes are retained in `tools/toolchain/msvc/portablemsvc.lock`. The installer log is `toolchain-msvc-install.log`.

For a repeat extraction, keep `PORTABLEMSVC_CACHE`, `PORTABLEMSVC_DATA`, `PORTABLEMSVC_CONFIG`, and `PORTABLEMSVC_TEMP` under `tools/toolchain`, create those directories first, and use `portablemsvc install-from-lockfile` with the retained lockfile. Do not redistribute the Microsoft compiler/SDK packages or extracted tools without checking their applicable Microsoft terms.

Official references: [ReXGlue prerequisites](https://github.com/rexglue/rexglue-sdk/wiki/Getting-Started), [LLVM 22.1.8](https://github.com/llvm/llvm-project/releases/tag/llvmorg-22.1.8), [CMake 4.4.3](https://github.com/Kitware/CMake/releases/tag/v4.4.3), [Ninja 1.13.2](https://github.com/ninja-build/ninja/releases/tag/v1.13.2), [Microsoft component catalog](https://learn.microsoft.com/en-us/visualstudio/install/workload-component-id-vs-build-tools?view=vs-2022), [PortableMSVC source](https://github.com/tgbender/portablemsvc).
