# Saint-Lo initialization diagnostics

These optional hooks observe the exact native-crash path from the supplied
`saint_lo.dll` XEX. They do not replace game behavior: each calls its original
`__imp__sub_*` generated body with the same `PPCContext`, then logs stack and
nonvolatile-register changes. There are no forced-success returns, null-pointer
substitutions, register restoration, or changes to clocks or physics.

Root integration can enable them after mission CMake targets exist:

```cmake
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../integration/saintlo-diagnostics"
                 saintlo-diagnostics)
cod3_enable_saintlo_diagnostics(cod3_pc_saint_lo)
```

The hooks log the first four invocations and at most the first sixteen preservation
failures per function. All records start with `[saintlo-diag]`. Stack reads use
`ReadProcessMemory` on the current process; invalid addresses are recorded as
unreadable. `parent112_r30` is an explicitly labelled contextual probe for the
112-byte `sub_891BE760` frame, not a general stack unwinder.

Observed fault: host `cod3_pc_saint_lo.DLL + 0x5BEE42`, guest instruction
`0x89132800: lwz r11,0x5104(r30)`, generated source line 18789 in the initial build.
The guest fault address `0x00005004` suggests `r30 = 0xFFFFFF00` instead of the
earlier `0x89250000`, provided the native offset register retained its correct
value. The wrappers isolate whether corruption is present before or after
`sub_89099818`, `sub_891BE760`, and its nested helpers. They are diagnostic only;
the root cause is not assumed to be the SDK heap issue being investigated elsewhere.

The later heap-patched run proved `sub_89099818` returns with a different guest SP
while its original saved r30/r31 stack slots remain intact. The next
`sub_891BE760` correctly preserves that already changed state. The wrapper now
also logs a `script-dispatch` record for the `_load.bro:161` invocation of
`_introscreen::main`, including actual engine API targets and closure fields.
Those strings describe a script call and are not a proven assertion message.
See `analysis/cod3-saintlo-nonlocal-findings.md` for the current evidence.
