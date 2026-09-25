# PPC/VMX precision gate

The guarded candidate layer in [`integration/ppc-math/vmx_semantics.h`](../../integration/ppc-math/vmx_semantics.h) is a native, opt in math boundary for the CoD3 PC port. It is disabled by default with `COD3_PPC_MATH_ENABLE_GUARDED_PATCH=0`; no generated game function, ReXGlue SDK header, game asset, clock, simulation step, or physics policy is changed by including the header.

Run the gate from PowerShell with:

```powershell
& '.\tests\ppc-math\run.ps1'
```

The machine result is recorded in [`ppc-math-precision.json`](ppc-math-precision.json). The current run passed 25,269 assertions, including 25,230 randomized checks, with zero assertion failures. It extracted eleven exact blocks from `cod3-pc/generated/default`; the candidate matched the independent reference for every case. The 15 recorded baseline differences are expected evidence of the generated ReXGlue paths that motivated the guarded layer, not a claim that those paths were rewritten.

The independent references follow these pinned Xenia paths:

* `tools/Xenia-source/src/xenia/cpu/ppc/ppc_emit_altivec.cc` documents VMX denormal input flushing for `vmaddfp`, the `vmsum3fp128`/`vmsum4fp128` dot operations, and unsigned saturating pack semantics.
* `tools/Xenia-source/src/xenia/cpu/backend/x64/x64_sequences.cc` emits FMA for `MUL_ADD_V128`, accumulates dot products in float64 and rounds once to float32, and canonicalizes finite dot overflow.
* `tools/Xenia-source/src/xenia/cpu/backend/x64/x64_seq_vector.cc` contains the VMX `FLOAT16_2`/`FLOAT16_4` pack and unpack layouts and the unsigned halfword saturation path.
* `tools/Xenia-source/src/xenia/base/math.h` defines the extended-range Xenos half conversion. Exponent 31 is finite in this encoding; denormals are discarded for the tested vpkd3d/vupkd3d forms.

The exact CoD3 sites are kept in `tests/ppc-math/actual_blocks.json` and are extracted by `tests/ppc-math/extract_blocks.py`. The corpus covers:

* fused `vmaddfp`, cancellation, intermediate overflow, VMX input/output denormals, signed zero, qNaN, and sNaN;
* `vmsum3fp128` and `vmsum4fp128` operation order, ignored W for the three term form, finite overflow to qNaN, denormal output, signed zero, qNaN, and 5,000 finite vector pairs;
* `vpkd3d128` FLOAT16_2/FLOAT16_4 layouts, alias safe insertion masks, extended range, signed zeros, denormals, NaN saturation, ties to even, and the independent Xenos conversion algorithm;
* `vupkd3d128` FLOAT16_2/FLOAT16_4 alias sites, half denormal-to-signed-zero behavior, extended-range values, and randomized packed values; and
* `vpkuhus` unsigned saturation with a destination alias, including values above `0x7FFF` that expose the signed-pack trap.

`VmxScope` saves and restores the complete host MXCSR. It forces VMX round-to-nearest, DAZ, and FTZ only for the scoped candidate operation, while scalar FPSCR rounding remains untouched. The helper uses explicit bit-level denormal normalization because a C++ `std::fma` implementation is allowed to bypass the host DAZ behavior that the native FMA instruction uses. Dot products pin every float64 product and addition to the Xenia grouping before the one float32 conversion. Half packing builds a temporary before merging it into the destination so an aliased destination cannot destroy a source halfword.

This gate is a precision artifact, not a gameplay certification. The report records `game_executed=false`, `integrated_into_game=false`, and `fps_or_physics_validation=false`. A future integration must select individual generated instruction boundaries, keep the default macro disabled until that review, and rerun gameplay and fixed-step physics checks separately. No global fast-math flag or simulation clock change is appropriate for this patch.
