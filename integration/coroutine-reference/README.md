# Original-opcode coroutine reference

This reference is independent of the native bridge: it reads the user's original
XEX modules, verifies their full SHA256 identities, reconstructs their images,
verifies the exact instruction-block hashes, and interprets those PPC words. It
does not import the bridge implementation or SDK-generated C++ function bodies.

The register and memory values in the fixtures are **synthetic**. The instruction
streams are verified original game instructions. Passing these tests establishes
a narrow register-frame contract, not working gameplay or correct scheduling.

## Contract established by the original instructions

The main restore block is `824A63AC..824A6484` (exclusive end, 216 bytes, SHA256
`A2CAA5B951D86CE5CDFDB4A42B6A398E81A185AB1EDD6A97F149F58A4B50797E`).

The Saint-Lo capture prefixes are `89190630..8919073C` and
`89190760..8919086C`. Both are 268 bytes and are **byte-identical**, SHA256
`7D2D89493D62C6A88CEEE0A8787509A5AE6C741CB259FF85698E277E43DF19F5`.
The last instruction is the first indirect call to stack-save API68; the
external callee, later wait/event API and scheduler are outside the reference.

At capture-helper entry the original instructions first overwrite `r11` with
`0xFFFFFFFF892552C4`, copy entry `r1` to `r10`, and store the low 32-bit entry SP
to guest global `0x892552C4`. Only then do they decrement SP by 400 and save
registers. Therefore an interception at helper ENTRY must account for these
side effects: the frame's r10/r11 slots contain the overwritten values.

| Frame offset | Size | Original capture data | Restore behavior |
|---|---:|---|---|
| 0..7 | 8 | Untouched | Not read |
| 8..239 | 29 × 8 | GPR3..GPR31, including overwritten r10/r11 | Big-endian 64-bit loads |
| 240..383 | 18 × 8 | FPR14..FPR31 raw bits | Big-endian 64-bit loads, no float conversion |
| 384..387 | 4 | CR | **Not restored** |
| 388..391 | 4 | Low 32 bits of entry LR | `lwz`, zero-extend to 64 bits, then `mtlr` |
| 392..399 | 8 | Full 64-bit entry CTR | `ld`, then `mtctr` |

The restore begins with `or r1,r11,r10`; normally both inputs contain the same
saved frame address. It restores CTR and LR via scratch r14, then overwrites
r14 from its GPR frame slot, restores the other saved registers, advances SP by
400 and executes `blr`. Branch target low two bits are cleared. LR itself keeps
the loaded low two bits.

**CR is saved but the observed restore tail never reads it or executes `mtcrf`.**
The CR at restore entry remains live. `r0`, `r2`, FPR0..13, all vector registers,
XER and FPSCR also remain the incoming restore values; they are not part of this
restore operation. Do not infer a whole-PPCContext restore from this frame.

The saved LR is from entry to the capture helper. The later API68 `bctrl`
overwrites live LR with `8919073C` / `8919086C`, but the already-written frame
retains the caller continuation. Reference fixtures explicitly distinguish both.

## Running and consuming

From the repository root, use the bundled Python runtime:

```powershell
& $python integration/coroutine-reference/coroutine_reference.py --cases 32
& $python -m unittest discover -s tests/coroutine-reference -p 'test_*.py' -v
```

Here `$python` is
`python`.
`cryptography` is required by the existing original-image reconstruction helper;
Capstone is not required by this interpreter.

Generation writes `tests/coroutine-reference/generated/contract.json`,
`vectors.json`, and `vectors.hpp`. The C++ header exposes
`cod3::coroutine_reference_vectors::kVectors` and `kVectorCount`, with 400-byte
frame arrays, incoming/expected full register states, 432-byte guarded initial
memory and expected global SP. Vector lanes are represented as low64/high64
halves. The contract's memory-access offsets come from decoded operands.
The fixture state includes all GPRs, raw FPR bits, vector bits, CR, LR, CTR, XER,
FPSCR and PC. Each vector includes frame bytes, global-SP output, exact call and
return events, and expected capture/restore states. The first vector deliberately
contains signed/unsigned boundaries, signaling/quiet NaN payloads, negative zero
and LR low bits. These are artificial validation inputs, never claimed as a
gameplay capture.

Guest data addresses are truncated to the 32-bit Xenon user virtual address
space; register arithmetic retains 64-bit wraparound. Unmapped accesses,
unsupported opcodes and changed source/stream hashes raise errors. No gameplay
function is patched, invoked or implemented here.
