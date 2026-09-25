// Guarded native PPC/VMX math candidates for the CoD3 port.
//
// This header is deliberately standalone: including it does not replace any
// ReXGlue generated function and does not change the game's clock, physics
// step, or global floating point policy.  A caller must opt in by calling the
// functions in cod3::ppc_math explicitly.
//
// The operation order and conversion rules are transcribed from the pinned
// Xenia sources listed in docs/reports/ppc-math-precision.json.  The helper
// signatures use the installed ReXGlue PPCVRegister by value so an aliasing
// destination cannot change a source while an operation is still reading it.
#pragma once

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <limits>
#include <type_traits>

#include <rex/ppc/context.h>

namespace cod3::ppc_math {

// The patch is intentionally opt-in.  The test harness uses the helpers
// directly; the game remains on generated ReXGlue code until an integration
// review wires a selected operation into a generated boundary.
#ifndef COD3_PPC_MATH_ENABLE_GUARDED_PATCH
#define COD3_PPC_MATH_ENABLE_GUARDED_PATCH 0
#endif

static_assert(sizeof(PPCVRegister) == 16);
static_assert(alignof(PPCVRegister) == 16);
static_assert(std::is_trivially_copyable_v<PPCVRegister>);

using VmxFmaFunction = PPCVRegister (*)(PPCVRegister, PPCVRegister,
                                        PPCVRegister) noexcept;
using VmxDotFunction = PPCVRegister (*)(PPCVRegister, PPCVRegister) noexcept;
static_assert(std::is_same_v<decltype(static_cast<VmxFmaFunction>(nullptr)),
                             VmxFmaFunction>);
static_assert(std::is_same_v<decltype(static_cast<VmxDotFunction>(nullptr)),
                             VmxDotFunction>);

inline uint32_t float_bits(float value) noexcept {
  return std::bit_cast<uint32_t>(value);
}

inline float bits_float(uint32_t value) noexcept {
  return std::bit_cast<float>(value);
}

inline bool is_float_denormal_bits(uint32_t bits) noexcept {
  return (bits & 0x7F800000u) == 0 && (bits & 0x007FFFFFu) != 0;
}

// Xenia's VMX path uses a separate MXCSR mode.  POWER8/Xbox VMX semantics
// flush denormal inputs as well as denormal results, and retain the sign when
// a denormal becomes zero.  Do this by bits so the helper remains correct even
// when a C++ library fma implementation ignores DAZ/FTZ.
inline float flush_vmx_denormal(float value) noexcept {
  const uint32_t bits = float_bits(value);
  return is_float_denormal_bits(bits) ? bits_float(bits & 0x80000000u) : value;
}

inline float flush_vmx_result(float value) noexcept {
  return flush_vmx_denormal(value);
}

inline PPCVRegister flush_vmx_inputs(PPCVRegister value) noexcept {
  for (float& lane : value.f32) lane = flush_vmx_denormal(lane);
  return value;
}

inline PPCVRegister flush_vmx_results(PPCVRegister value) noexcept {
  for (float& lane : value.f32) lane = flush_vmx_result(lane);
  return value;
}

class VmxScope {
 public:
  VmxScope() noexcept : saved_(simde_mm_getcsr()) {
    // Keep exception flags and unrelated host policy from the caller, while
    // forcing VMX's round-to-nearest and denormal handling.  The destructor
    // restores the entire CSR, including flags raised by the candidate.
    constexpr uint32_t kRoundMask = uint32_t(SIMDE_MM_ROUND_MASK);
    constexpr uint32_t kFlushMask = uint32_t(SIMDE_MM_FLUSH_ZERO_MASK);
    constexpr uint32_t kDazMask = 0x0040u;
    constexpr uint32_t kExceptionMask = 0x1F80u;
    simde_mm_setcsr((saved_ & ~(kRoundMask | kFlushMask | kDazMask)) |
                    kFlushMask | kDazMask | kExceptionMask);
  }

  ~VmxScope() { simde_mm_setcsr(saved_); }

  VmxScope(const VmxScope&) = delete;
  VmxScope& operator=(const VmxScope&) = delete;

 private:
  uint32_t saved_;
};

// VMX vmaddfp is a fused multiply-add in Xenia's x64 FMA sequence.  The
// explicit input/output normalization supplies the POWER/Xbox denormal rule
// even when std::fma is lowered to a library call that does not consult DAZ.
inline PPCVRegister vmadd(PPCVRegister a, PPCVRegister multiplier,
                           PPCVRegister addend) noexcept {
  VmxScope mode;
  a = flush_vmx_inputs(a);
  multiplier = flush_vmx_inputs(multiplier);
  addend = flush_vmx_inputs(addend);

  PPCVRegister result{};
  for (unsigned lane = 0; lane != 4; ++lane) {
    result.f32[lane] = flush_vmx_result(
        std::fma(a.f32[lane], multiplier.f32[lane], addend.f32[lane]));
  }
  return result;
}

static_assert(std::is_same_v<decltype(&vmadd), VmxFmaFunction>);

// The x64 Xenia DOT_PRODUCT_3 sequence converts each float to double, rounds
// each product to double, adds X+Z first, then adds Y, and finally rounds once
// to float.  ReXGlue stores guest X,Y,Z,W at host lanes 3,2,1,0.
template <unsigned N>
inline PPCVRegister dot(PPCVRegister a, PPCVRegister b) noexcept {
  static_assert(N == 3 || N == 4);
  VmxScope mode;
  a = flush_vmx_inputs(a);
  b = flush_vmx_inputs(b);

  // Volatile temporaries pin the same intermediate precision and grouping as
  // vmulpd/vaddsd/vaddpd in Xenia, even if a caller uses a permissive compiler
  // configuration around this header.
  volatile double p0 = double(a.f32[3]) * double(b.f32[3]);
  volatile double p1 = double(a.f32[2]) * double(b.f32[2]);
  volatile double p2 = double(a.f32[1]) * double(b.f32[1]);
  volatile double grouped;
  if constexpr (N == 3) {
    grouped = p0 + p2;
    grouped = grouped + p1;
  } else {
    volatile double p3 = double(a.f32[0]) * double(b.f32[0]);
    volatile double pair_xz = p0 + p2;
    volatile double pair_yw = p1 + p3;
    grouped = pair_xz + pair_yw;
  }

  const float rounded = flush_vmx_result(float(grouped));
  uint32_t bits = float_bits(rounded);
  // Xenia's non-fast dot path maps finite-double -> float32 overflow to its
  // canonical qNaN, but preserves an infinity or NaN that already occurred in
  // the input/operation.
  if (std::isfinite(double(grouped)) &&
      (bits & 0x7F800000u) == 0x7F800000u) {
    bits = 0x7FC00000u;
  }

  PPCVRegister result{};
  for (uint32_t& lane : result.u32) lane = bits;
  return result;
}

static_assert(std::is_same_v<decltype(&dot<3>), VmxDotFunction>);

// Xenia's float_to_xenos_half with denormal preservation disabled.  Xenos
// float16 is an extended-range format: exponent 31 is finite and values at or
// above the threshold saturate to 0x7FFF, rather than IEEE binary16 infinity.
inline uint16_t xenos_half(float value, bool round_to_nearest_even) noexcept {
  const uint32_t input = float_bits(value);
  const uint32_t magnitude = input & 0x7FFFFFFFu;
  uint32_t result;
  if (magnitude >= 0x47FFE000u) {
    result = 0x7FFFu;
  } else {
    result = magnitude < 0x38800000u ? 0u : magnitude + 0xC8000000u;
    if (round_to_nearest_even) {
      result += 0xFFFu + ((result >> 13u) & 1u);
    }
    result = (result >> 13u) & 0x7FFFu;
  }
  return uint16_t(result | ((input & 0x80000000u) >> 16u));
}

inline float xenos_half_to_float(uint16_t value) noexcept {
  uint32_t mantissa = value & 0x3FFu;
  uint32_t exponent = (value >> 10u) & 0x1Fu;
  if (!exponent) {
    // The VMX/Xenos conversion used by vupkd3d128 flushes half denormals and
    // keeps their sign.  No arithmetic is needed for this branch.
    return bits_float(uint32_t(value & 0x8000u) << 16u);
  }
  const uint32_t result = (uint32_t(value & 0x8000u) << 16u) |
                          ((exponent + 112u) << 23u) | (mantissa << 13u);
  return bits_float(result);
}

// Implements vpkd3d128 FLOAT16_2/FLOAT16_4 mask and shift insertion.  The
// temporary is built before the merge so vd==vb/vd==va cannot consume a word
// that the instruction has already overwritten.
inline PPCVRegister pack_half(PPCVRegister destination, PPCVRegister source,
                              unsigned type, unsigned mask,
                              unsigned shift) noexcept {
  if (mask < 1 || mask > 3 || shift > 3) return destination;
  PPCVRegister packed{};
  const bool four = type == 5;
  const auto pair = [&](unsigned guest_index) -> uint32_t {
    return (uint32_t(xenos_half(source.f32[3 - guest_index], four)) << 16) |
           xenos_half(source.f32[2 - guest_index], four);
  };
  if (four) {
    packed.u32[1] = pair(0);
    packed.u32[0] = pair(2);
  } else if (type == 3) {
    packed.u32[0] = pair(0);
  } else {
    return destination;
  }

  if (mask == 1 || (mask == 2 && shift == 3)) {
    destination.u32[shift] = packed.u32[0];
  } else if ((mask == 2 || mask == 3) && shift < 3) {
    destination.u32[shift] = packed.u32[0];
    destination.u32[shift + 1] = packed.u32[1];
  } else if (mask == 3 && shift == 3) {
    destination.u32[0] = packed.u32[1];
  }
  return destination;
}

// Implements the matching vupkd3d128 FLOAT16_2/FLOAT16_4 layout.  Returning
// a new register and taking source by value gives alias safe behavior for
// vD==vB while keeping the fixed constants in the unused FLOAT16_2 lanes.
inline PPCVRegister unpack_half(PPCVRegister source, unsigned type) noexcept {
  PPCVRegister result{};
  if (type == 3) {
    result.f32[3] = xenos_half_to_float(source.u16[7]);
    result.f32[2] = xenos_half_to_float(source.u16[6]);
    result.f32[1] = 0.0f;
    result.f32[0] = 1.0f;
  } else if (type == 5) {
    for (unsigned guest_index = 0; guest_index != 4; ++guest_index) {
      result.f32[3 - guest_index] =
          xenos_half_to_float(source.u16[7 - guest_index]);
    }
  }
  return result;
}

// Xenia's PACK_TYPE_8_IN_16 unsigned -> unsigned saturated path.  Copying
// both inputs before writing makes the helper safe when the destination aliases
// either source, while preserving ReXGlue's reversed host lane order.
inline PPCVRegister pack_unsigned_halfwords(PPCVRegister a,
                                            PPCVRegister b) noexcept {
  PPCVRegister result{};
  for (unsigned i = 0; i != 8; ++i) {
    result.u8[15 - i] = uint8_t(std::min(a.u16[7 - i], uint16_t(255)));
    result.u8[7 - i] = uint8_t(std::min(b.u16[7 - i], uint16_t(255)));
  }
  return result;
}

}  // namespace cod3::ppc_math
