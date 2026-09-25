# COD3 Xenos semantic contract

This is an isolated, read-only audit model for the observed Call of Duty 3
Xbox 360 shader containers. It is deliberately separate from
`tools/XenosRecomp` and from the ReXGlue GPU plugin so that a semantic change
can be reviewed and tested before it is integrated into either active tree.

The model covers the metadata and binding rules that are easy to lose while
porting the legacy `0x102A10xx` containers:

- exact `0x102A1000`, `0x102A1001`, and `0x102A1021` flag classification;
- legacy definition lists at `table + 0x20`, including primary and secondary
  table selection for dual containers;
- stage-relative float register banks, generated shared bool word mapping, and
  the legacy vertex sampler slot shift of 16;
- vertex fetch address identity alongside declaration ordinal, so repeated
  `POSITION0`/`NORMAL0` declarations cannot alias silently;
- Xenia's fetch word 4 LOD bias/exponent decoding and explicit LOD sum;
- Xenia's cube ALU tie-breaking and the TC/SC/face inverse projection.

`xenos_semantics.py` contains only pure parsing and math helpers. Unknown
metadata or binding combinations raise `ValueError`; a missing host binding
must remain visible to the eventual renderer.

## Run the audit

From `<workspace>`:

```powershell
$python = 'python'
& $python integration/xenos-semantics/audit.py .
```

The audit reads the prepared manifest, the control-flow texture inventory, the
recorded XenosRecomp conversion report, and the legacy layout reports. It does
not open the ISO, execute the game, or change compiler/runtime files.

## Run tests

```powershell
cmake -S integration/xenos-semantics -B integration/xenos-semantics/build -G Ninja
cmake --build integration/xenos-semantics/build
ctest --test-dir integration/xenos-semantics/build --output-on-failure -V
```

