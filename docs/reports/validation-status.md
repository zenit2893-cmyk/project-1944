# COD3 workspace audit

Recorded UTC: 2026-09-13T13:13:14.1336301Z
Project: <workspace>\cod3-pc

This report separates tool readiness and build artifacts from actual game correctness. It never treats a scaffold, SDK smoke test, executable, or synthetic timing test as a working game.

| Gate | State | Evidence / limitation |
| --- | --- | --- |
| input-present | **PASS** | The named ISO is present. This check does not validate the entire disc image. |
| sdk-smoke | **PASS** | The supplied SDK CLI runs and reports its version. Runtime compatibility with COD3 is a later gate. |
| xenosrecomp-tool | **PASS** | XenosRecomp executes and displays its no-argument usage. This does not establish linkage or runtime interoperability with ReXGlue. |
| xenonrecomp-tool | **PASS** | XenonRecomp executes and displays its no-argument usage. This does not establish linkage or runtime interoperability with ReXGlue. |
| xenonanalyse-tool | **FAIL** | XenonAnalyse executable is absent, not probed, or failed its no-argument usage check. |
| native-toolchain | **PASS** | Fresh tool version probes and recorded compile/link/run smoke checks pass; source and executable hashes match. This is SDK/toolchain evidence, not gameplay. |
| extracted-xex | **PASS** | default.xex exists with an XEX2 header and a recorded SHA256. This does not assert that all game assets are extracted. |
| codegen-success | **PASS** | Successful recorded code generation matches the current XEX, manifest and declared module inputs, with generated guest C++ artifacts. Semantic correctness remains unverified. |
| native-build | **PASS** | Successful recorded build has a matching AMD64 executable and declared native mission modules. Boot and gameplay require separate observations. |
| boot | **NOT_VERIFIED** | No reviewed evidence for this game stage is recorded. SDK, generated C++, EXE existence and synthetic tests do not satisfy it. |
| gameplay | **NOT_VERIFIED** | No reviewed evidence for this game stage is recorded. SDK, generated C++, EXE existence and synthetic tests do not satisfy it. |
| render-120fps | **NOT_VERIFIED** | No reviewed evidence for this game stage is recorded. SDK, generated C++, EXE existence and synthetic tests do not satisfy it. |
| physics-invariance | **NOT_VERIFIED** | No reviewed evidence for this game stage is recorded. SDK, generated C++, EXE existence and synthetic tests do not satisfy it. |

Detailed paths, hashes, tool output and receipt information are in validation-status.json. Acceptance requirements are in validation-acceptance.md.

Exit 0 only means the audit completed. A requested -RequireThrough gate returns exit 2 if its prerequisite checks are unmet. Game observation stages are never automatically certified by this script.
