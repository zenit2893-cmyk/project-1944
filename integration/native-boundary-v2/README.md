# Native boundary v2

This directory documents the boundary used by the CoD3 PC build. The audit is
implemented in `scripts/native-boundary-v2/audit_native_boundary.py` and writes
the machine-readable and human-readable receipts under `docs/reports/`.

The native application is `cod3_pc.exe` plus the fifteen `cod3_pc_<mission>.dll`
title modules. Each title module must be an AMD64 PE image linked from its
ReXGlue-generated `cod3_pc_init.cpp`, `cod3_pc_register.cpp`, and
`cod3_pc_recomp.*.cpp` objects. The executable must link the generated default
entrypoint and the ReXGlue runtime. The four local support DLLs are tracked in
the same PE closure: `cod3_coroutines.dll`, `rexruntimerd.dll`,
`rexgpu-xenosrd.dll`, and `TracyClientrd.dll`.

The Xenia reuse boundary is source-level and GPU-only. The pinned Xenia
D3D12 sampling change is compiled by the isolated
`integration/xenia-graphics` `OBJECT` target; that target has no executable or
shared-library link output and is not part of `cod3-pc/out/build/.../build.ninja`.
The active app uses ReXGlue's Xenos GPU plugin. Xenia source names and GPU
shader translation terminology can therefore appear in the runtime/plugin;
the audit reports them as allowed GPU semantics. `xenia_canary.exe`, Xenia's
guest CPU/JIT path, and the unintegrated `integration/xenia-kernel/candidate`
file must not enter the native application graph.

XenonRecomp is a bounded exception: the host may contain exactly the two
opcode-verified thunk bodies recorded in
`integration/xenon/generated/thunks.provenance.json`. The complete XenonRecomp
output and its context/runtime are excluded from the host link.

Run the static check from the workspace root:

```powershell
& '.\scripts\native-boundary-v2\audit_native_boundary.ps1' -Check
```

The command does not launch the game or an emulator. A passing receipt proves
the inspected build graph and PE boundary at that point in time. It cannot
prove runtime DLL search paths, GPU initialization, gameplay compatibility,
120 FPS frame pacing, or physics invariance.
