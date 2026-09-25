#pragma once

// Minimal include-only fixture for the lexical XenonRecomp seam.  The real
// selected Xenon output remains under analysis/title-xenon-generated and is
// not modified by this test.
[[gnu::noinline]] inline uint64_t cod3_selected_xenon_mftb_expression() noexcept {
  return __rdtsc();
}
