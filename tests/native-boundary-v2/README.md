# Native boundary v2 test

`run.ps1` invokes the static PE, Ninja, provenance, and Xenia-isolation audit.
It writes the current receipts to `docs/reports/native-boundary-v2.json` and
`docs/reports/native-boundary-v2.md` and exits nonzero for a boundary failure.

```powershell
& '.\tests\native-boundary-v2\run.ps1'
```

This test intentionally does not launch `cod3_pc.exe`, `xenia_canary.exe`, or
the game. Runtime and differential tests remain necessary for gameplay,
renderer initialization, 120 FPS frame pacing, and physics correctness.
