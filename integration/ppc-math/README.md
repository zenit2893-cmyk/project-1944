# Guarded PPC/VMX math layer

`vmx_semantics.h` contains explicit, native candidates for the small set of
VMX operations that the CoD3 generated code currently emits with a different
precision or aliasing behavior than the pinned Xenia x64 path. It is a testable
header, not a replacement SDK or emulator runtime.

The default is deliberately disabled:

```text
COD3_PPC_MATH_ENABLE_GUARDED_PATCH=0
```

The functions use the installed ReXGlue `PPCVRegister` layout and pass it by
value. `VmxScope` saves and restores the complete MXCSR, forces VMX
round-to-nearest/DAZ/FTZ only for its scope, and explicitly flushes denormal
inputs and results because a C++ library `fma` may not apply DAZ in the same
way as an x64 FMA instruction. `dot<3>` and `dot<4>` preserve Xenia's float64
product and addition order before the final float32 conversion. The Xenos
half converters use the extended-range encoding from Xenia, including signed
zero and denormal handling. Pack helpers build a temporary before alias-safe
insertion.

The test harness in `tests/ppc-math` extracts exact straight-line blocks from
`cod3-pc/generated/default` and compares these candidates with independent
native Xenia sequences and bit-level conversion references. It does not launch
the game and it does not modify generated game sources, the SDK, game assets,
the simulation clock, or the physics step.
