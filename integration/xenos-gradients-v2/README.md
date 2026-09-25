# XenosRecomp CoD3 gradient contract

This directory contains the isolated validation harness for the legacy Call
of Duty 3 texture-gradient adapter. It exercises the existing XenosRecomp
working tree and writes compiler artifacts under `artifacts/`; it does not
modify the ISO, launch Call of Duty 3, launch Xenia, or modify the ReXGlue SDK,
GPU runtime, or `cod3-pc` sources.

The shader implementation is pinned to Xenia source revision
`0e1307bd2e6bfeeff29635a6b823e72e61c97ce9`. The attribution and BSD-3-Clause
license are retained in `tools/XenosRecomp/XENIA-GRADIENT-NOTICE.txt` and
`tools/XenosRecomp/XENIA-GRADIENT-LICENSE`.

Run from the workspace root:

```powershell
.\integration\xenos-gradients-v2\Run-Validation.ps1
```

Use `-RebuildXenos` when the XenosRecomp source has changed. The run converts
the prepared 437-container corpus into its 610 single or explicitly selected
dual entries, compiles every generated HLSL file to DXIL and SPIR-V, checks
that every input hash is unchanged, and then runs the independent gradient
oracle. The oracle checks the X/Z and Y/W derivative layout, Xenia's cube
major-axis tie ordering and inverse projection, signed fetch word 4 fields,
and the 2D/cube `SampleGrad` call-site counts.

The expected contract counts are 332 `GetTextureGradients`, 30 horizontal and
30 vertical gradient stores, and 36 explicit-gradient samples (9 2D and 27
cube). Each explicit sample must refer to the actual guest sampler slot via
`g_CoD3TextureFetchWord4[8]`; the harness rejects a missing reference,
zero/default substitution, or a remaining `#error` variant marker.

`docs/reports/xenos-gradients-v2-batch.json` records per-entry compiler and
input-hash evidence. `docs/reports/xenos-gradients-v2.json` records the
contract result. Passing these files establishes compiler and translation
coverage. It does not establish runtime descriptor uploads, sampler state,
game renderer binding, visual parity, or a running 120 FPS game.
