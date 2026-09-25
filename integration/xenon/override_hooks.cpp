#include "xenon_thunks.h"

#include <rex/hook.h>

// Supported raw hooks replace only the two weak ReXGlue entry symbols.
// Their __imp__sub_* original implementations remain available to a debugger.
REX_HOOK_RAW(sub_822D0498) {
  [[clang::musttail]] return cod3_xenon_thunk_822D0498(ctx, base);
}

REX_HOOK_RAW(sub_822D2140) {
  [[clang::musttail]] return cod3_xenon_thunk_822D2140(ctx, base);
}

