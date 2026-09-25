#include "xenon_thunks.h"

// These are original ReXGlue-generated guest functions. REX_EXTERN fixes their
// C linkage and exact (PPCContext&, uint8_t*) ABI. The selected Xenon bodies use
// the same direct guest-call form as ReXGlue's own output.
REX_EXTERN(sub_822D0118);
REX_EXTERN(sub_822CBA28);

// Only the function/prologue contract is enabled. This bridge deliberately has
// no PPC memory, MMIO, indirect dispatch, clock, or exception compatibility API.
#define PPC_FUNC_IMPL(name) REX_EXTERN(name)
#define PPC_FUNC_PROLOGUE() __builtin_assume(((size_t)base & 0x1F) == 0)
#define __imp__sub_822D0498 cod3_xenon_thunk_822D0498
#define __imp__sub_822D2140 cod3_xenon_thunk_822D2140

#include "generated/thunks.generated.inl"

#undef __imp__sub_822D2140
#undef __imp__sub_822D0498
#undef PPC_FUNC_PROLOGUE
#undef PPC_FUNC_IMPL

