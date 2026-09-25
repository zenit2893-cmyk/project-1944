# Xenia/ReXGlue memory and MMIO contract

This report records the isolated memory contract used to review the native
Call of Duty 3 port.  It is based on the local source copies, not on an
emulator run:

- `tools/Xenia-source/src/xenia/memory.cc` and `memory.h` (BSD-licensed Xenia
  source kept in this workspace).
- `tools/rexglue-source/src/system/xmemory.cpp` and
  `tools/rexglue-source/include/rex/system/xmemory.h` (the ReXGlue memory
  port).
- `tools/rexglue-source/src/system/mmio_handler.cpp` and
  `tools/rexglue-source/include/rex/system/mmio_handler.h` (the ReXGlue
  MMIO/exception ABI).
- `tools/rexglue-source/resources/templates/codegen/pch_h.inja` and the
  generated `cod3-pc/generated/default/cod3_pc_pch.h` (the emitted native
  access macros).

The new code in `integration/xenia-memory/` is original BSD-3-Clause glue
code.  It contains no copied Xenia implementation and is not linked into the
active SDK, `cod3-pc`, game sources, or generated game C++.  The two headers
provide a checked address contract and an isolated callback table for tests or
later integration:

- `xenia_memory_contract.h` classifies guest ranges, resolves the Xenia and
  ReXGlue physical-address policies, applies the `0xE0000000` host offset only
  when the 4 KB physical heap owns the address, and provides checked virtual,
  physical, and host-to-guest transforms.
- `xenia_mmio_contract.h` preserves the ReXGlue callback ABI and Xenia's
  first-match mask lookup while making a no-match result explicit.

## Confirmed layout

The local Xenia map has these boundaries:

| Guest range | Xenia meaning | Physical/host rule |
|---|---|---|
| `0x00000000–0x3FFFFFFF` | Virtual 4 KB | Virtual view, no physical alias conversion |
| `0x40000000–0x7EFFFFFF` | Virtual 64 KB | Virtual view, no physical alias conversion |
| `0x7F000000–0x7FC7FFFF` | GPU writeback/XPS alias | Physical alias to offset `0` |
| `0x7FC80000–0x7FFFFFFF` | MMIO | Routed to a registered MMIO range |
| `0x80000000–0x8FFFFFFF` | XEX 64 KB | Virtual view, no physical alias conversion |
| `0x90000000–0x9FFFFFFF` | XEX 4 KB | Virtual view, no physical alias conversion |
| `0xA0000000–0xBFFFFFFF` | Physical 64 KB aliases | Physical offset `guest - 0xA0000000` |
| `0xC0000000–0xDFFFFFFF` | Physical 16 MB aliases | Physical offset `guest - 0xC0000000` |
| `0xE0000000–0xFFCCFFFF` | Physical 4 KB aliases | Physical offset `guest - 0xE0000000 + 0x1000` |
| `0xFFD00000–0xFFFFFFFF` | No heap metadata | Reserved view may exist, but the guest heap does not own it |

The map and the v7F overlay are visible in Xenia's `memory.cc:60-70`,
`memory.cc:230-250`, `memory.cc:304-358`, and `memory.cc:412-462`.  ReXGlue
keeps the same file-view layout at `xmemory.cpp:51-60`, `xmemory.cpp:258-312`,
and `xmemory.cpp:361-371`, but its `Memory` object does not initialize a v7F
`PhysicalHeap`; its `LookupHeap` returns no heap for the entire `0x7F...`
window (`xmemory.cpp:400-420`).  The mapping is therefore still an addressable
view for raw GPU work, while `Memory::GetPhysicalAddress` in ReXGlue rejects
that alias (`xmemory.cpp:457-464`).  The adapter exposes this as two explicit
policies rather than silently treating the runtimes as identical.

Both implementations keep the physical 4 KB heap's physical offset at
`0x1000`: `PhysicalHeap::GetPhysicalAddress` adds it for an `E...` heap
(`tools/Xenia-source/src/xenia/memory.cc:2428-2435` and
`tools/rexglue-source/src/system/xmemory.cpp:2350-2358`).  Host translation has
a second, independent concern.  When host allocation granularity is larger
than 4 KB, the file mapping rounds the view offset down and the host pointer
must add `0x1000`; ReXGlue computes this at heap initialization in
`xmemory.cpp:1876-1887`.  A checked caller must therefore use the runtime
granularity, not just a platform name.  The generated pch currently encodes a
compile-time Windows/macOS predicate at
`resources/templates/codegen/pch_h.inja:128-133`.

`TranslatePhysical` uses the 512 MB aperture mask `0x1FFFFFFF` after the
caller has identified the value as a physical address.  The adapter keeps this
operation separate from guest-pointer conversion so a malformed guest pointer
cannot be made into a host pointer by accidental masking.  Xenia's historical
`Memory::GetPhysicalAddress` also passes through canonical physical values
strictly below `0x1FFFFFFF` (`memory.cc:526-537`); ReXGlue's implementation
requires a `GuestPhysical` heap (`xmemory.cpp:457-464`).  The distinction is
covered by `PhysicalResolutionPolicy` and by regression checks.

## MMIO and exception behavior

GPU and XMA register windows are registered as mask ranges with
`address = 0x7FC80000` or `0x7FEA0000`, `mask = 0xFFFF0000`, and metadata size
`0xFFFF`.  The registration sites are
`tools/rexglue-source/src/graphics/graphics_system.cpp:140-147` and
`tools/rexglue-source/src/audio/xma_decoder.cpp:93-102`.  The handler's
`LookupRange`, `CheckLoad`, and `CheckStore` match `(guest & mask) == address`
and return the first matching range (`src/system/mmio_handler.cpp:82-123`).
The `size` field is retained metadata; it is not an additional match
predicate.

The callback ABI is exactly:

```cpp
uint32_t read(void* ppc_context, void* callback_context, uint32_t address);
void write(void* ppc_context, void* callback_context,
           uint32_t address, uint32_t value);
```

The exception path first accepts only faults between the virtual membase and
the inclusive `memory_end` (`src/system/mmio_handler.cpp:371-405`), treats a
fault below `physical_membase` as a virtual guest candidate, converts it back
with `HostToGuestVirtual`, and then looks up an MMIO range.  A fault in the
physical backing view is passed to the memory access callback instead.  The
adapter's `ClassifyFaultAddress` keeps this inclusive upper-bound behavior
explicit.

## Blockers found in the active generated path

The generated ReXGlue pch uses:

```cpp
#define REX_IS_MMIO_ADDR(addr) ((addr) >= 0x7F000000u && (addr) < 0x80000000u)
```

This is broader than Xenia's actual MMIO range.  A generated load or store
that is selected for an address in `0x7F000000–0x7FC7FFFF` can therefore call
`CheckLoad`/`CheckStore` even though that address is the GPU writeback/XPS
alias.  A no-match `CheckLoad` returns `false` and leaves its output untouched
(`src/system/mmio_handler.cpp:105-123`), while the generated `REX_MM_LOAD_*`
macros ignore that boolean (`resources/templates/codegen/pch_h.inja:199-239`;
the same code is present in `cod3-pc/generated/default/cod3_pc_pch.h:145-239`).
The isolated adapter reports this divergence and requires callers to honor a
failed dispatch.  It does not patch generated files or widen an MMIO handler
to cover physical memory.

The direct generated `REX_RAW_ADDR`/`REX_LOAD_*` operations also perform raw
`base + uint32_t(address) + offset` arithmetic.  The latest saved run proves
that code generation and startup reached the game, but it did not prove memory
or gameplay correctness: `logs/cod3-pc-run-20260905-100006.log:1-18` records
the RTX 5070 device, memory bases `0x0000000100000000` and
`0x0000000200000000`, and the GPU/XMA startup path; the same run reaches the
Saint-Lo script dispatch at line 71 and then stops on
`Unhandled guest access violation: read of guest 0x00000010` at line 72.  That
fault is a null/invalid guest access at `0x10`, not evidence that a physical
address offset or MMIO range should be masked away.  The generated Saint-Lo
function remains outside this isolated adapter's scope.

## Validation

`tests/xenia-memory/` builds a standalone executable with the local toolchain
and no ReXGlue SDK or Xenia binary.  It covers the map boundaries, the v7F
policy difference, `E...` physical and host offsets, physical aperture
masking, inverse host translation, inclusive exception bounds, MMIO range
matching, callback argument identity, first-match behavior, and the generated
predicate divergence.

Command:

```powershell
& '.\tests\xenia-memory\Run.ps1' -Configuration RelWithDebInfo
```

Observed result on 2026-09-13 with the bundled Clang 22.1.8/CMake/Ninja
toolchain:

```text
RESULT 38/38 passed
100% tests passed out of 1
Total Test time (real) =   0.41 sec
```

No game launch, emulator launch, generated-file edit, SDK edit, or host-memory
protection bypass was performed for this audit.
