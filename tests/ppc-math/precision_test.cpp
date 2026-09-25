// Independent native differential checks for the guarded PPC/VMX math layer.
//
// The generated functions included below are extracted from real CoD3
// generated C++ by extract_blocks.py.  The reference routines are deliberately
// written independently from the candidate helpers: Xenia's x64 instruction
// order is expressed with native intrinsics, while the Xenos conversions are
// transcribed as separate bit algorithms.
#include "actual_generated_blocks.h"
#include "../../integration/ppc-math/vmx_semantics.h"

#include <array>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <immintrin.h>
#include <limits>
#include <string>
#include <type_traits>

namespace candidate = cod3::ppc_math;

static unsigned assertions = 0;
static unsigned failures = 0;
static unsigned baseline_differences = 0;
static unsigned generated_cases = 0;
static unsigned random_cases = 0;
static const char* active_case = "startup";

static PPCVRegister guest(uint32_t x, uint32_t y, uint32_t z, uint32_t w) {
  PPCVRegister result{};
  result.u32[3] = x;
  result.u32[2] = y;
  result.u32[1] = z;
  result.u32[0] = w;
  return result;
}

static PPCVRegister splat(uint32_t value) {
  return guest(value, value, value, value);
}

static std::string hex(PPCVRegister value) {
  char out[80];
  std::snprintf(out, sizeof(out), "%08X %08X %08X %08X", value.u32[3],
                value.u32[2], value.u32[1], value.u32[0]);
  return out;
}

static bool equal(PPCVRegister left, PPCVRegister right) {
  return std::memcmp(&left, &right, sizeof(left)) == 0;
}

static uint32_t bits(float value) { return std::bit_cast<uint32_t>(value); }

static void check(bool okay) {
  ++assertions;
  if (!okay) {
    ++failures;
    std::printf("{\"case\":\"%s\",\"candidate_pass\":false}\n",
                active_case);
  }
}

static void observe(const char* name, PPCVRegister baseline,
                    PPCVRegister proposed, PPCVRegister expected,
                    bool baseline_must_differ = false) {
  active_case = name;
  const bool baseline_differs = !equal(baseline, expected);
  const bool proposed_pass = equal(proposed, expected);
  baseline_differences += baseline_differs;
  ++generated_cases;
  check(proposed_pass);
  if (baseline_must_differ) check(baseline_differs);
  std::printf(
      "{\"case\":\"%s\",\"baseline\":\"%s\",\"candidate\":\"%s\","
      "\"expected\":\"%s\",\"baseline_differs\":%s,\"candidate_pass\":%s}\n",
      name, hex(baseline).c_str(), hex(proposed).c_str(), hex(expected).c_str(),
      baseline_differs ? "true" : "false", proposed_pass ? "true" : "false");
}

static void observe_scalar(const char* name, uint32_t baseline,
                           uint32_t proposed, uint32_t expected,
                           bool baseline_must_differ = false) {
  active_case = name;
  const bool baseline_differs = baseline != expected;
  const bool proposed_pass = proposed == expected;
  baseline_differences += baseline_differs;
  ++generated_cases;
  check(proposed_pass);
  if (baseline_must_differ) check(baseline_differs);
  std::printf(
      "{\"case\":\"%s\",\"baseline\":\"%08X\",\"candidate\":\"%08X\","
      "\"expected\":\"%08X\",\"baseline_differs\":%s,\"candidate_pass\":%s}\n",
      name, baseline, proposed, expected, baseline_differs ? "true" : "false",
      proposed_pass ? "true" : "false");
}

namespace reference {

static float flush_input(float value) {
  const uint32_t value_bits = std::bit_cast<uint32_t>(value);
  if ((value_bits & 0x7F800000u) == 0 &&
      (value_bits & 0x007FFFFFu) != 0) {
    return std::bit_cast<float>(value_bits & 0x80000000u);
  }
  return value;
}

static PPCVRegister flush_inputs(PPCVRegister value) {
  for (float& lane : value.f32) lane = flush_input(lane);
  return value;
}

static PPCVRegister flush_results(PPCVRegister value) {
  for (float& lane : value.f32) lane = flush_input(lane);
  return value;
}

// This is the native instruction sequence Xenia emits for a VMX FMA when the
// x64 FMA feature is enabled.  0x9FC0 is Xenia's VMX MXCSR: round-nearest,
// exception masks, DAZ, and FTZ.
static PPCVRegister vmadd(PPCVRegister a, PPCVRegister b, PPCVRegister c) {
  const unsigned saved = _mm_getcsr();
  _mm_setcsr(0x9FC0u);
  a = flush_inputs(a);
  b = flush_inputs(b);
  c = flush_inputs(c);
  PPCVRegister result{};
  _mm_store_ps(result.f32,
               _mm_fmadd_ps(_mm_load_ps(a.f32), _mm_load_ps(b.f32),
                            _mm_load_ps(c.f32)));
  result = flush_results(result);
  _mm_setcsr(saved);
  return result;
}

template <unsigned N>
static PPCVRegister dot(PPCVRegister a, PPCVRegister b) {
  static_assert(N == 3 || N == 4);
  const unsigned saved = _mm_getcsr();
  _mm_setcsr(0x9FC0u);
  a = flush_inputs(a);
  b = flush_inputs(b);

  // Convert ReXGlue's host lanes [w,z,y,x] to Xenia's [x,y,z,w].
  __m128 av0 = _mm_load_ps(a.f32);
  __m128 bv0 = _mm_load_ps(b.f32);
  __m128 av = _mm_shuffle_ps(av0, av0, 0x1B);
  __m128 bv = _mm_shuffle_ps(bv0, bv0, 0x1B);
  if constexpr (N == 3) {
    const __m128 mask = _mm_castsi128_ps(_mm_set_epi32(0, -1, -1, -1));
    av = _mm_and_ps(av, mask);
    bv = _mm_and_ps(bv, mask);
  }

  const __m256d products =
      _mm256_mul_pd(_mm256_cvtps_pd(av), _mm256_cvtps_pd(bv));
  __m128d low = _mm256_castpd256_pd128(products);
  __m128d high = _mm256_extractf128_pd(products, 1);
  __m128d sum;
  if constexpr (N == 3) {
    const __m128d y = _mm_unpackhi_pd(low, low);
    low = _mm_add_sd(low, high);  // x + z
    sum = _mm_add_sd(low, y);     // (x + z) + y
  } else {
    low = _mm_add_pd(low, high);  // [x + z, y + w]
    sum = _mm_add_sd(low, _mm_unpackhi_pd(low, low));
  }

  const __m128 rounded = _mm_cvtsd_ss(_mm_setzero_ps(), sum);
  uint32_t result_bits = uint32_t(
      _mm_cvtsi128_si32(_mm_castps_si128(rounded)));
  const uint32_t result_sign = result_bits & 0x80000000u;
  if ((result_bits & 0x7F800000u) == 0 &&
      (result_bits & 0x007FFFFFu) != 0) {
    result_bits = result_sign;
  }
  const uint64_t double_bits = uint64_t(
      _mm_cvtsi128_si64(_mm_castpd_si128(sum)));
  if ((result_bits & 0x7F800000u) == 0x7F800000u &&
      ((double_bits >> 52) & 0x7FFu) != 0x7FFu) {
    result_bits = 0x7FC00000u;
  }
  _mm_setcsr(saved);
  return splat(result_bits);
}

// Independent transcription of Xenia's float_to_xenos_half.  Denormals are
// intentionally not preserved for vpkd3d128 FLOAT16_2/FLOAT16_4.
static uint16_t xenos_half(float value, bool nearest_even) {
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

static float xenos_half_to_float(uint16_t value) {
  uint32_t mantissa = value & 0x3FFu;
  uint32_t exponent = (value >> 10u) & 0x1Fu;
  if (!exponent) {
    // The tested Xenia path uses preserve_denormal=false.
    return std::bit_cast<float>(uint32_t(value & 0x8000u) << 16u);
  }
  return std::bit_cast<float>((uint32_t(value & 0x8000u) << 16u) |
                              ((exponent + 112u) << 23u) |
                              (mantissa << 13u));
}

static PPCVRegister pack_half(PPCVRegister destination, PPCVRegister source,
                              unsigned type, unsigned mask,
                              unsigned shift) {
  const bool four = type == 5;
  uint32_t packed0 = 0;
  uint32_t packed1 = 0;
  const auto pair = [&](unsigned guest_index) -> uint32_t {
    const uint16_t high = xenos_half(source.f32[3 - guest_index], four);
    const uint16_t low = xenos_half(source.f32[2 - guest_index], four);
    return (uint32_t(high) << 16) | uint32_t(low);
  };
  if (four) {
    packed0 = pair(2);
    packed1 = pair(0);
  } else if (type == 3) {
    packed0 = pair(0);
  } else {
    return destination;
  }

  if (mask == 1 || (mask == 2 && shift == 3)) {
    destination.u32[shift] = packed0;
  } else if ((mask == 2 || mask == 3) && shift < 3) {
    destination.u32[shift] = packed0;
    destination.u32[shift + 1] = packed1;
  } else if (mask == 3 && shift == 3) {
    destination.u32[0] = packed1;
  }
  return destination;
}

static PPCVRegister unpack_half(PPCVRegister source, unsigned type) {
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

static PPCVRegister pack_unsigned_halfwords(PPCVRegister a, PPCVRegister b) {
  PPCVRegister result{};
  for (unsigned i = 0; i != 8; ++i) {
    const uint16_t a_value = a.u16[7 - i];
    const uint16_t b_value = b.u16[7 - i];
    result.u8[15 - i] = a_value > 255 ? 255 : uint8_t(a_value);
    result.u8[7 - i] = b_value > 255 ? 255 : uint8_t(b_value);
  }
  return result;
}

}  // namespace reference

static void test_static_contract() {
  static_assert(sizeof(PPCVRegister) == 16);
  static_assert(alignof(PPCVRegister) == 16);
  static_assert(std::is_trivially_copyable_v<PPCVRegister>);
  static_assert(std::is_same_v<decltype(&candidate::vmadd),
                               candidate::VmxFmaFunction>);
  static_assert(std::is_same_v<decltype(&candidate::dot<3>),
                               candidate::VmxDotFunction>);
  check(true);
}

static void test_vmadd() {
  const PPCVRegister golden =
      guest(0x3F800000, 0x3FC00000, 0x3F8CCCCD, 0x3FF33333);
  observe("vmadd_fma_rounding", actual::vmadd(golden, golden, golden),
          candidate::vmadd(golden, golden, golden),
          reference::vmadd(golden, golden, golden), true);

  PPCVRegister a = splat(0x3F800001);
  PPCVRegister b = splat(0x3F7FFFFE);
  PPCVRegister c = splat(0xBF800000);
  observe("vmadd_cancellation", actual::vmadd(a, b, c),
          candidate::vmadd(a, b, c), reference::vmadd(a, b, c), true);

  a = splat(0x7F7FFFFF);
  b = splat(0x40000000);
  c = splat(0xFF7FFFFF);
  observe("vmadd_intermediate_overflow", actual::vmadd(a, b, c),
          candidate::vmadd(a, b, c), reference::vmadd(a, b, c), true);

  a = splat(0x00800000);
  b = splat(0x3F000000);
  c = a;
  observe("vmadd_result_denormal_flush", actual::vmadd(a, b, c),
          candidate::vmadd(a, b, c), reference::vmadd(a, b, c));

  a = splat(0x00000001);
  b = splat(0x3F800000);
  c = splat(0);
  observe("vmadd_input_denormal_flush", actual::vmadd(a, b, c),
          candidate::vmadd(a, b, c), reference::vmadd(a, b, c));

  a = guest(0x80000000, 0x00000000, 0x80000000, 0x00000000);
  b = splat(0x3F800000);
  c = splat(0x80000000);
  observe("vmadd_signed_zero", actual::vmadd(a, b, c),
          candidate::vmadd(a, b, c), reference::vmadd(a, b, c));

  a = splat(0x7FC01234);
  b = splat(0x3F800000);
  c = splat(0x40000000);
  observe("vmadd_qnan_payload", actual::vmadd(a, b, c),
          candidate::vmadd(a, b, c), reference::vmadd(a, b, c));

  a = splat(0x3F800000);
  b = splat(0x7F812345);
  c = splat(0x40000000);
  observe("vmadd_snan_payload", actual::vmadd(a, b, c),
          candidate::vmadd(a, b, c), reference::vmadd(a, b, c));
}

static void test_dot_products() {
  PPCVRegister a = guest(0x3F800000, 0x3FC00000, 0x3F8CCCCD, 0x01020304);
  PPCVRegister b = guest(0x40000000, 0x40700000, 0x4013D70A, 0x01020304);
  observe("dot3_accumulation_order", actual::dot3(a, b),
          candidate::dot<3>(a, b), reference::dot<3>(a, b));

  a = guest(0x4B800000, 0x3F800000, 0xCB800000, 0x7F800000);
  b = splat(0x3F800000);
  observe("dot3_ignored_w_and_cancellation", actual::dot3(a, b),
          candidate::dot<3>(a, b), reference::dot<3>(a, b), true);

  a = guest(0x4B800000, 0x3F800000, 0xCB800000, 0x3F800000);
  observe("dot4_accumulation_order", actual::dot4(a, b),
          candidate::dot<4>(a, b), reference::dot<4>(a, b), true);

  a = guest(0x7F7FFFFF, 0, 0, 0);
  b = guest(0x40000000, 0, 0, 0);
  observe("dot3_finite_overflow_qnan", actual::dot3(a, b),
          candidate::dot<3>(a, b), reference::dot<3>(a, b), true);

  a = guest(0x80800000, 0, 0, 0);
  b = guest(0x3F000000, 0, 0, 0);
  observe("dot3_negative_denormal_output", actual::dot3(a, b),
          candidate::dot<3>(a, b), reference::dot<3>(a, b));
  observe("dot4_negative_denormal_output", actual::dot4(a, b),
          candidate::dot<4>(a, b), reference::dot<4>(a, b));

  a = splat(0x7FC05678);
  b = splat(0x3F800000);
  observe("dot3_qnan_payload", actual::dot3(a, b), candidate::dot<3>(a, b),
          reference::dot<3>(a, b));

  a = guest(0x80000000, 0, 0, 0);
  b = guest(0x3F800000, 0, 0, 0);
  observe("dot3_signed_zero", actual::dot3(a, b), candidate::dot<3>(a, b),
          reference::dot<3>(a, b));

  uint32_t state = 0xC0D30003u;
  const auto next = [&]() {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
  };
  for (unsigned sample = 0; sample != 5000; ++sample) {
    active_case = "dot_random_differential";
    PPCVRegister va{}, vb{};
    for (unsigned lane = 0; lane != 4; ++lane) {
      // Finite values only: this loop checks operation ordering independently
      // of the explicit exceptional counterexamples above.
      va.u32[lane] = (next() & 0x807FFFFFu) | ((next() % 240u + 7u) << 23);
      vb.u32[lane] = (next() & 0x807FFFFFu) | ((next() % 240u + 7u) << 23);
    }
    check(equal(candidate::dot<3>(va, vb), reference::dot<3>(va, vb)));
    check(equal(candidate::dot<4>(va, vb), reference::dot<4>(va, vb)));
    random_cases += 2;
  }
}

static void test_pack_unpack() {
  const PPCVRegister sentinel = splat(0xCDCDCDCDu);
  PPCVRegister a = guest(0x3FC00000, 0xBFC00000, 0x42A23EC8, 0x403DB757);
  observe("pack_half2_layout", actual::half2_distinct(a, sentinel),
          candidate::pack_half(sentinel, a, 3, 1, 3),
          reference::pack_half(sentinel, a, 3, 1, 3));

  a = guest(0x47800000, 0x38000000, 0, 0);
  observe("pack_half2_extended_range", actual::half2_distinct(a, sentinel),
          candidate::pack_half(sentinel, a, 3, 1, 3),
          reference::pack_half(sentinel, a, 3, 1, 3));

  a = guest(0xBF800000, 0x3F000000, 0x3F800000, 0xC0000000);
  observe("pack_half4_alias", actual::half4_alias(a),
          candidate::pack_half(a, a, 5, 2, 2),
          reference::pack_half(a, a, 5, 2, 2));

  a = guest(0x3F803000, 0x3F801000, 0xBF803000, 0xBF801000);
  observe("pack_half4_round_ties_even", actual::half4_alias(a),
          candidate::pack_half(a, a, 5, 2, 2),
          reference::pack_half(a, a, 5, 2, 2));

  a = guest(0x80000000, 0x00000000, 0x00000001, 0x7FC01234);
  active_case = "pack_half_invalid_control";
  check(equal(candidate::pack_half(sentinel, a, 3, 0, 0), sentinel));
  check(equal(candidate::pack_half(sentinel, a, 3, 1, 4), sentinel));
  for (unsigned type : {3u, 5u}) {
    for (unsigned mask : {1u, 2u, 3u}) {
      for (unsigned shift = 0; shift != 4; ++shift) {
        active_case = "pack_half_mask_differential";
        const PPCVRegister expected = reference::pack_half(
            sentinel, a, type, mask, shift);
        const PPCVRegister proposed =
            candidate::pack_half(sentinel, a, type, mask, shift);
        check(equal(proposed, expected));
        random_cases++;
      }
    }
  }

  PPCVRegister pa{}, pb{};
  for (unsigned i = 0; i != 8; ++i) {
    pa.u16[i] = uint16_t(i + 1);
    pb.u16[i] = uint16_t(0x80F0u + i);
  }
  observe("pack_unsigned_halfwords_alias", actual::pack_unsigned_alias(pa, pb),
          candidate::pack_unsigned_halfwords(pa, pb),
          reference::pack_unsigned_halfwords(pa, pb));

  for (unsigned i = 0; i != 8; ++i) {
    pa.u16[i] = uint16_t((i * 977u) & 0xFFFFu);
    pb.u16[i] = uint16_t((0xFFFFu - i * 313u) & 0xFFFFu);
  }
  check(equal(candidate::pack_unsigned_halfwords(pa, pb),
             reference::pack_unsigned_halfwords(pa, pb)));

  const std::array<uint16_t, 14> half_values = {
      0x0000, 0x8000, 0x0001, 0x8001, 0x03FF, 0x83FF, 0x0400,
      0x8400, 0x3C00, 0xBC00, 0x7C00, 0xFC00, 0x7FFF, 0xFFFF};
  for (uint16_t x : half_values) {
    for (uint16_t y : half_values) {
      active_case = "unpack_half2_special_differential";
      PPCVRegister packed{};
      packed.u16[7] = x;
      packed.u16[6] = y;
      const PPCVRegister expected = reference::unpack_half(packed, 3);
      const PPCVRegister proposed = candidate::unpack_half(packed, 3);
      check(equal(proposed, expected));
      random_cases++;
    }
  }

  PPCVRegister unpack4{};
  unpack4.u16[7] = 0x3800;
  unpack4.u16[6] = 0xB800;
  unpack4.u16[5] = 0x3C00;
  unpack4.u16[4] = 0xBC00;
  observe("unpack_half2_alias", actual::unpack_half2_alias(unpack4),
          candidate::unpack_half(unpack4, 3),
          reference::unpack_half(unpack4, 3));
  observe("unpack_half4_alias", actual::unpack_half4_alias(unpack4),
          candidate::unpack_half(unpack4, 5),
          reference::unpack_half(unpack4, 5));

  // Compare the exact generated unpack blocks on a mix of zero, signed zero,
  // subnormal, finite extended-range, and sign-bearing values.
  for (uint32_t seed : {0x00000000u, 0x80008001u, 0x7FFF7C00u,
                        0xFFFFFC00u, 0x040003FFu}) {
    active_case = "unpack_half_seed_differential";
    PPCVRegister source = sentinel;
    source.u32[3] = seed;
    const PPCVRegister expected2 = reference::unpack_half(source, 3);
    const PPCVRegister expected4 = reference::unpack_half(source, 5);
    check(equal(candidate::unpack_half(source, 3), expected2));
    check(equal(candidate::unpack_half(source, 5), expected4));
    random_cases += 2;
  }

  uint32_t state = 0x51A7C0DEu;
  const auto next = [&]() {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
  };
  for (unsigned sample = 0; sample != 5000; ++sample) {
    active_case = "xenos_half_conversion_differential";
    const float value = std::bit_cast<float>(next());
    check(candidate::xenos_half(value, false) ==
          reference::xenos_half(value, false));
    check(candidate::xenos_half(value, true) ==
          reference::xenos_half(value, true));
    random_cases += 2;

    active_case = "unpack_half4_differential";
    PPCVRegister packed = sentinel;
    packed.u32[3] = next();
    packed.u32[2] = next();
    check(equal(candidate::unpack_half(packed, 5),
                reference::unpack_half(packed, 5)));
    random_cases++;
  }

  // 2:10:10:10 and other pack forms are not covered by this guarded layer;
  // keep the corpus explicit so callers do not accidentally interpret a
  // FLOAT16-only proof as broad VMX coverage.
  check(bits(reference::xenos_half_to_float(0x8000)) == 0x80000000u);
  check(bits(reference::xenos_half_to_float(0x0001)) == 0x00000000u);
}

static void test_vmx_scope_and_scalar_rounding() {
  _mm_setcsr(0x1F80u | 0x4000u | 0x20u);  // scalar round-up + sticky flag
  active_case = "vmx_scope_rounding";
  const unsigned before = _mm_getcsr();
  const PPCVRegister one = splat(0x3F800000u);
  const PPCVRegister half_ulp = splat(0x33800000u);  // 2^-24
  const PPCVRegister nearest = candidate::vmadd(one, one, half_ulp);
  check(nearest.u32[0] == 0x3F800000u);
  check(_mm_getcsr() == before);

  // Dot's VMX mode must also ignore scalar round-up and restore the host word.
  const PPCVRegister dot_result = candidate::dot<3>(
      guest(0x3F800000u, 0, 0, 0), guest(0x33800000u, 0, 0, 0));
  active_case = "vmx_scope_dot_rounding";
  check(dot_result.u32[0] == 0x33800000u);
  check(_mm_getcsr() == before);
  _mm_setcsr(0x1F80u);
}

int main() {
  test_static_contract();
  test_vmadd();
  test_dot_products();
  test_pack_unpack();
  test_vmx_scope_and_scalar_rounding();

  std::printf(
      "{\"summary\":true,\"assertions\":%u,\"assertion_failures\":%u,"
      "\"baseline_differences\":%u,\"generated_cases\":%u,"
      "\"random_checks\":%u,\"guarded_patch_enabled\":%s,"
      "\"game_executed\":false,\"fps_validated\":false}\n",
      assertions, failures, baseline_differences, generated_cases, random_cases,
      COD3_PPC_MATH_ENABLE_GUARDED_PATCH ? "true" : "false");
  return failures ? 1 : 0;
}
