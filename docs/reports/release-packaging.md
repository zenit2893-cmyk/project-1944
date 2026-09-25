# Native-port release packaging audit

The packaging implementation is under `scripts/release-package/` and
`integration/release-packaging/`. It produces separate `native-runtime`,
`developer-source`, and provenance-only `toolchain` bundles. The runtime
allowlist contains `cod3_pc.exe`, the native mission/helper DLLs, and
`rexgpu-xenosrd.dll`, `rexruntimerd.dll`, and `TracyClientrd.dll`. The source
allowlist contains the native project, integrations, scripts, tests, and
textual reports needed to reproduce the build.

Every bundle carries a sorted SHA-256 payload manifest, sanitized build
evidence, toolchain provenance, and the required license files. License
provenance is declared in
`integration/release-packaging/license-manifest.json`; the staged notices
cover the project, ReXGlue, Xenia-derived graphics/shader code, XenosRecomp,
XenonRecomp, and SDL3. `THIRD-PARTY-NOTICES.md` records the pinned source
revisions and the boundary between native runtime code and optional analysis
tools.

The script fails closed when a successful build receipt is absent or its
executable/DLL hashes do not match the files being staged. This check matters
because a stale receipt can otherwise make a changed native build look
reproducible. During this audit the saved receipt and current `cod3_pc.exe`
were different, so an authoritative runtime archive was deliberately not
issued. `-SkipReceiptValidation` exists for local staging inspection only and
marks `build-evidence.json` as `skipped_by_request`.

The developer staging inspection completed with 5,744 files and no forbidden
path or extension. It excludes the ISO and archives, `game/`, all XEX and
extracted game data, generated guest C++, shader outputs/caches, build trees,
PDB/OBJ/debug dumps, and compiler payloads. The runtime inspection completed
with 19 native binaries and no forbidden path or extension. The toolchain
provenance ZIP was written twice from identical inputs and produced the same
SHA-256, demonstrating the fixed timestamp and sorted-entry archive path.

## Commands

Run from the workspace root in PowerShell 7:

```powershell
.\scripts\release-package\New-Cod3Package.ps1 -Bundle Developer
.\scripts\release-package\New-Cod3Package.ps1 -Bundle Runtime
.\scripts\release-package\New-Cod3Package.ps1 -Bundle Both
```

Use `-Force` only to replace the exact staging/archive paths. Use
`-SkipArchive` when inspecting a staging directory. Do not use
`-SkipReceiptValidation` for a release candidate; it is intended to verify
the allowlist while another build is still changing local artifacts.

The `native-runtime` bundle still needs a legally obtained, user-owned game
data tree supplied separately. The `developer-source` bundle also needs the
matching game input and separately obtained SDK/toolchain components. The
toolchain record does not redistribute MSVC or the Windows SDK. No game was
launched by the packaging audit, and the receipt makes no claim about boot,
gameplay, rendering correctness, physics invariance, or 120 FPS.

