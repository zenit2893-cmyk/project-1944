// Standalone, unintegrated native candidate implementations for CoD3 instruction
// validation. No decoder, guest dispatch loop, JIT, or emulator process is used.
//
// Portions adapted from Xenia, Copyright 2015 Ben Vanik and contributors.
// BSD-3-Clause; see LICENSE.xenia in this directory. Source provenance and
// limits are recorded in NOTICE.md. ReXGlue register layout is used by value.
#pragma once

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <limits>
#include <rex/ppc/context.h>

namespace cod3::ppc_math {

// Mirrors Xenia's separate VMX MXCSR bank, as a scoped native implementation.
// Do not mutate the SDK's cached FPSCR word: restore exactly what was live on
// entry, including scalar rounding mode, flush flags and host exception masks.
// This is a correctness-first per-operation prototype, not a hot-path policy.
class VmxScope {
 public:
  VmxScope() noexcept : saved_(simde_mm_getcsr()) {
    simde_mm_setcsr((saved_ & ~uint32_t(SIMDE_MM_ROUND_MASK)) |
                    uint32_t(SIMDE_MM_FLUSH_ZERO_MASK) | 0x0040u | 0x1F80u);
  }
  ~VmxScope() { simde_mm_setcsr(saved_); }
  VmxScope(const VmxScope&) = delete;
  VmxScope& operator=(const VmxScope&) = delete;
 private:
  uint32_t saved_;
};

inline PPCVRegister vmadd(PPCVRegister a, PPCVRegister multiplier,
                          PPCVRegister addend) noexcept {
  VmxScope mode;
  PPCVRegister result{};
  for (unsigned lane = 0; lane != 4; ++lane) {
    result.f32[lane] = std::fma(a.f32[lane], multiplier.f32[lane], addend.f32[lane]);
  }
  return result;
}

// Xenia x64 DOT_PRODUCT_3/4 operation order, translated from emitted x86
// instructions into native C++. Rex host lane 3 is guest X, lane 0 is guest W.
template <unsigned N>
inline PPCVRegister dot(PPCVRegister a, PPCVRegister b) noexcept {
  static_assert(N == 3 || N == 4);
  VmxScope mode;
  const double p0 = double(a.f32[3]) * double(b.f32[3]);
  const double p1 = double(a.f32[2]) * double(b.f32[2]);
  const double p2 = double(a.f32[1]) * double(b.f32[1]);
  double sum;
  if constexpr (N == 3) {
    sum = (p0 + p2) + p1;
  } else {
    const double p3 = double(a.f32[0]) * double(b.f32[0]);
    sum = (p0 + p2) + (p1 + p3);
  }
  const float rounded = float(sum);
  uint32_t bits = std::bit_cast<uint32_t>(rounded);
  // Exact Xenia default path: finite double -> non-finite float overflow maps
  // to canonical qNaN. Infinities / NaNs already in inputs are preserved.
  if (std::isfinite(sum) && ((bits & 0x7F800000u) == 0x7F800000u)) {
    bits = 0x7FC00000u;
  }
  PPCVRegister result{};
  for (auto& word : result.u32) word = bits;
  return result;
}

// Adapted from Xenia src/xenia/base/math.h float_to_xenos_half. The aliasing
// cast has been replaced by bit_cast; preserve_denormal=false is intentional.
// Xenos half uses exponent 31 for finite values, unlike IEEE binary16.
inline uint16_t xenos_half(float value, bool nearest_even) noexcept {
  const uint32_t input = std::bit_cast<uint32_t>(value);
  const uint32_t magnitude = input & 0x7FFFFFFFu;
  uint32_t result;
  if (magnitude >= 0x47FFE000u) {
    result = 0x7FFFu;
  } else {
    result = magnitude < 0x38800000u ? 0u : magnitude + 0xC8000000u;
    if (nearest_even) result += 0xFFFu + ((result >> 13u) & 1u);
    result = (result >> 13u) & 0x7FFFu;
  }
  return uint16_t(result | ((input & 0x80000000u) >> 16u));
}

// FLOAT16_2 (type 3) truncates; pinned Xenia FLOAT16_4 (type 5) rounds to even.
// Build a complete packed temporary before merging it into destination. This
// preserves source values / sign bits with vd==vb and implements the word mask.
inline PPCVRegister pack_half(PPCVRegister destination, PPCVRegister source,
                              unsigned type, unsigned mask, unsigned shift) noexcept {
  PPCVRegister packed{};
  const bool four = type == 5;
  const auto pair = [&](unsigned guest_index) -> uint32_t {
    return (uint32_t(xenos_half(source.f32[3 - guest_index], four)) << 16) |
           xenos_half(source.f32[2 - guest_index], four);
  };
  if (four) {
    packed.u32[1] = pair(0);
    packed.u32[0] = pair(2);
  } else {
    packed.u32[0] = pair(0);
  }
  if (mask == 1 || ((mask == 2) && shift == 3)) {
    destination.u32[shift] = packed.u32[0];
  } else if ((mask == 2 || mask == 3) && shift < 3) {
    destination.u32[shift] = packed.u32[0];
    destination.u32[shift + 1] = packed.u32[1];
  } else if (mask == 3 && shift == 3) {
    destination.u32[0] = packed.u32[1];
  }
  return destination;
}

// Xenia's saturating pack semantics, with ReXGlue's reversed host layout.
// Passing registers by value is essential when destination aliases a source.
inline PPCVRegister pack_unsigned_halfwords(PPCVRegister a, PPCVRegister b) noexcept {
  PPCVRegister result{};
  for (unsigned i = 0; i != 8; ++i) {
    result.u8[15 - i] = uint8_t(std::min(a.u16[7 - i], uint16_t(255)));
    result.u8[7 - i] = uint8_t(std::min(b.u16[7 - i], uint16_t(255)));
  }
  return result;
}

// Xenia's native x64 conversion is saturated if the hardware indefinite result
// came from a non-negative operand. The generated > double(LLONG_MAX) test
// misses exactly +2^63 because double(LLONG_MAX) already rounds to +2^63.
inline int64_t fctidz(double value) noexcept {
  if (std::isnan(value)) return std::numeric_limits<int64_t>::min();
  if (value >= 0x1p63) return std::numeric_limits<int64_t>::max();
  return simde_mm_cvttsd_si64(simde_mm_load_sd(&value));
}

}  // namespace cod3::ppc_math
