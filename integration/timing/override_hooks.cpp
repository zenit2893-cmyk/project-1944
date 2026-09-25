#include "candidate_observer.h"

// REX_EXTERN uses the SDK's exact raw hook signature. These strong symbols
// override the generated weak names. The __imp__ symbols remain the original
// ReXGlue bodies, avoiding dispatcher recursion and argument marshaling.
REX_EXTERN(__imp__sub_825298D8);
REX_EXTERN(__imp__sub_82536DD0);

REX_EXTERN(sub_825298D8) {
  cod3::timing::Observe(cod3::timing::Probe::MsNormalization,
                        __imp__sub_825298D8, ctx, base);
}

REX_EXTERN(sub_82536DD0) {
  cod3::timing::Observe(cod3::timing::Probe::OuterFrame,
                        __imp__sub_82536DD0, ctx, base);
}
