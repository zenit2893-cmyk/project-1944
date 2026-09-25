# Two verified XenonRecomp thunks on the ReXGlue ABI

This integration executes actual XenonRecomp-generated C++ for exactly two
Call of Duty 3 TU0 functions. It uses the installed ReXGlue SDK's `PPCContext`
directly. It does not include, copy, or cast the upstream Xenon context.

| Guest entry | Verified original instructions | Guest tail target |
|---|---|---|
| `0x822D0498` | `b 0x822D0118` (`4BFFFC80`) | ReXGlue `sub_822D0118` |
| `0x822D2140` | `addi r3,r3,4; b 0x822CBA28` (`38630004 4BFF98E4`) | ReXGlue `sub_822CBA28` |

The bodies in `generated/thunks.generated.inl` were selected verbatim from
`analysis/title-xenon-generated/ppc_recomp.32.cpp`. The receipt records the
original file SHA-256, source lines, input image hash, and original opcodes.
The adapter changes symbol names through macros and declares outgoing guest
calls with `REX_EXTERN`, exactly matching ReXGlue's raw guest ABI.

The generated signed 64-bit ADDI is compiled with `-fwrapv` on this object target
only, giving the required modulo-2^64 result for all input bit patterns. This
includes wrap past signed INT64_MAX and UINT64_MAX and carry across bit 32.

To attach the two supported raw hooks to an existing ReXGlue host after its
`find_package(rexglue ...)` and `add_executable(...)`:

```cmake
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../integration/xenon" xenon)
cod3_enable_xenon_thunk_overrides(cod3_pc)
```

The hooks override only `sub_822D0498` and `sub_822D2140` using the SDK's
`REX_HOOK_RAW`. They preserve the original ReXGlue `__imp__sub_*` symbols. The
two target functions are still provided by the ReXGlue-generated game module.
Do not add the entire Xenon-generated output to the host; its context, memory,
clock, imports, indirect dispatch, and exception contracts need further work.

Re-extraction is bounded and rejects any unexpected body or changed game image:

```powershell
& '.\integration\xenon\extract-generated-thunks.ps1' -GeneratedDirectory '.\analysis\title-xenon-generated'
& '.\tests\xenon-bridge\run.ps1'
```

The native test executes both direct and raw-hook entry points against an
independent decoder of the original PPC instruction words. Its 1,072 cases
exercise boundary and randomized register bit patterns; compare all 2,688
context bytes at the target; verify guest LR, context identity, memory-base
identity, a memory canary, exactly one target call, and return of the target's
changed register state. The Release object was also inspected and contains a
native `jmp`, or `addq $4` followed by `jmp`, with relocations to the intended
ReXGlue guest symbols.

These tests establish the two branch thunks' behavior. They do not establish
gameplay correctness or 120 FPS.
