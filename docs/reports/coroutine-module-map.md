# COD3 original coroutine module map

The all-module scan completed on 2026-09-13 against the 15 local mission
modules under `game/cod3/sp/*/*.dll`. It reconstructed each XEX image with the
local ReXGlue loader source, checked the locked Call of Duty 3 USA/Europe
identity, and matched the original PPC instruction bodies. The result is
45/45 capture functions and 15/15 modules at `verified` status.

The machine-readable evidence is in
`analysis/cod3-allmodule-coroutine-sites.json`. The input lock is
`analysis/cod3-allmodule-coroutine-manifest.json`; its SHA-256 is
`989539D2F73EE522D7745E4E78113608D2A26A2ACC9811518FD6EB9FE221E971`.
The scanner SHA-256 recorded in the JSON is
`8928D459876DBD67E49459AAF7476587560EC086DAFFB29A9BB29C08297822F7`.
The reconstruction source is
`tools/rexglue-source/src/system/xex_module.cpp`, locked by SHA-256
`AD048F1DB3AFA24BED6989CD44C64A84724C3835B1E5B65FAEBEF36008486E4E`.

## Exact body contract

Every candidate begins in an executable section with the same 58-instruction
prologue. It allocates 400 bytes with `addi r1,r1,-400`, saves GPR3..31 at
offsets 8..232, saves FPR14..31 at offsets 240..376, and stores CR, LR, and CTR
at offsets 384, 388, and 392. The common 10-instruction suffix must reload the
same saved-SP global, call the API68 transfer through the same module interface,
and restore the stack pointer.

The tail starts immediately after that suffix. A later API call inside a broad
search window is not accepted. The three exact tails are:

| Capture kind | Terminal API slot | Instructions | Bytes | Relocation pairs in the complete body |
| --- | ---: | ---: | ---: | ---: |
| timed wait | API76 (`0x4C`) | 76 | 304 | 5 |
| integer wait | API80 (`0x50`) | 76 | 304 | 5 |
| event wait | API84 (`0x54`) | 97 | 388 | 12 |

The tail grammar fixes every non-address opcode, including its argument load,
interface load, `mtctr`, and `bctrl`. The only masked fields are the low
immediate halves of consecutive `lis r11` / `addi r11,r11` pairs at the indices
listed in each capture's `relocation_mask_instruction_indices`. Each decoded
address must be inside that module's writable image data. Its displacement from
the module interface must also equal the Saint-Lo reference displacement.

## Identity and callers

Before scanning code, the analyzer checks title ID `415607E1`, media ID
`2E07093A`, version and base version `0.0.0.1`, platform and disc identity,
expected guest path and DLL stem, original PE name, XEX SHA-256, reconstructed
image SHA-256, PE image base `0x89000000`, and entry point. A ReXGlue loader
source hash and the expected encrypted/basic reconstruction mode are checked as
well. A wrong title or revision is rejected before any capture is reported.

For each body the scanner decodes every direct PPC `bl` whose target is the
capture entry. The evidence records the call address, branch word, target, and
continuation address (`call + 4`). A positive direct-caller count is required
for `verified`. These are static branch facts; they do not establish live
gameplay execution or coverage of every indirect call path.

The negative test suite in `tests/coroutine-map/test_coroutine_map.py` verifies
the 15-module identity lock, frame offsets, exact body counts, relocation masks,
continuation arithmetic, rejection of wrong title/revision metadata, and
rejection of a duplicated complete signature as ambiguous. Run it with:

```powershell
& 'python' `
  -m unittest discover -s tests/coroutine-map -p 'test_*.py' -v
```

The map is original-image static evidence. It does not claim that the native
PC bridge boots, that gameplay works, or that 120 FPS has been validated.
