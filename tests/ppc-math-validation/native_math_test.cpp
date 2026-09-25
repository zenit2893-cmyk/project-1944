// Native comparison of actual CoD3 emitted instruction blocks, SDK headers,
// pinned Xenia instruction algorithms and concrete expected bit patterns.
// Xenia-derived references below are BSD-3-Clause, Copyright 2015 Ben Vanik
// and contributors. See integration/ppc-math-validation/LICENSE.xenia.
#include "actual_generated_blocks.h"
#include "../../integration/ppc-math-validation/native_math_candidates.h"

#include <array>
#include <bit>
#include <cstdio>
#include <cstring>
#include <immintrin.h>
#include <string>

#pragma STDC FENV_ACCESS ON

namespace candidate = cod3::ppc_math;
static unsigned assertions = 0, errors = 0, mismatches = 0;

static PPCVRegister guest(uint32_t x, uint32_t y, uint32_t z, uint32_t w) {
  PPCVRegister result{};
  result.u32[3] = x; result.u32[2] = y; result.u32[1] = z; result.u32[0] = w;
  return result;
}
static PPCVRegister splat(uint32_t x) { return guest(x, x, x, x); }
static uint32_t fbits(float x) { return std::bit_cast<uint32_t>(x); }
static std::string hex(PPCVRegister v) {
  char out[80];
  std::snprintf(out, sizeof(out), "%08X %08X %08X %08X", v.u32[3], v.u32[2], v.u32[1], v.u32[0]);
  return out;
}
static std::string hex64(uint64_t x) {
  char out[24]; std::snprintf(out, sizeof(out), "%016llX", static_cast<unsigned long long>(x)); return out;
}
static bool equal(PPCVRegister a, PPCVRegister b) { return !std::memcmp(&a, &b, 16); }
static void check(bool okay) { ++assertions; errors += !okay; }
static void observe(const char* name, PPCVRegister baseline, PPCVRegister proposed,
                    PPCVRegister expected, bool must_differ = false) {
  bool differs = !equal(baseline, expected);
  bool okay = equal(proposed, expected);
  check(okay); if (must_differ) check(differs);
  mismatches += differs;
  std::printf("{\"case\":\"%s\",\"baseline\":\"%s\",\"candidate\":\"%s\",\"expected\":\"%s\",\"baseline_differs\":%s,\"candidate_pass\":%s}\n",
              name, hex(baseline).c_str(), hex(proposed).c_str(), hex(expected).c_str(),
              differs ? "true" : "false", okay ? "true" : "false");
}
static void observe64(const char* name, uint64_t baseline, uint64_t proposed,
                      uint64_t expected, bool must_differ = false) {
  const bool differs = baseline != expected, okay = proposed == expected;
  check(okay); if (must_differ) check(differs);
  mismatches += differs;
  std::printf("{\"case\":\"%s\",\"baseline\":\"%s\",\"candidate\":\"%s\",\"expected\":\"%s\",\"baseline_differs\":%s,\"candidate_pass\":%s}\n",
              name, hex64(baseline).c_str(), hex64(proposed).c_str(), hex64(expected).c_str(),
              differs ? "true" : "false", okay ? "true" : "false");
}

// Native x86 instruction references transcribed from pinned Xenia's emitted
// sequences. They execute compiled host instructions directly, with no JIT.
namespace reference {
__declspec(noinline) PPCVRegister vmadd(PPCVRegister a, PPCVRegister b, PPCVRegister c) {
  const unsigned saved = _mm_getcsr(); _mm_setcsr(0x9FC0);
  PPCVRegister result;
  _mm_store_ps(result.f32, _mm_fmadd_ps(_mm_load_ps(a.f32), _mm_load_ps(b.f32), _mm_load_ps(c.f32)));
  _mm_setcsr(saved); return result;
}
template <unsigned N>
__declspec(noinline) PPCVRegister dot(PPCVRegister a, PPCVRegister b) {
  const unsigned saved = _mm_getcsr(); _mm_setcsr(0x9FC0);
  // Convert ReXGlue's reversed host layout to Xenia's [x,y,z,w] host layout.
  __m128 av = _mm_shuffle_ps(_mm_load_ps(a.f32), _mm_load_ps(a.f32), 0x1B);
  __m128 bv = _mm_shuffle_ps(_mm_load_ps(b.f32), _mm_load_ps(b.f32), 0x1B);
  if constexpr (N == 3) {
    const auto mask = _mm_castsi128_ps(_mm_set_epi32(0, -1, -1, -1));
    av = _mm_and_ps(av, mask); bv = _mm_and_ps(bv, mask);
  }
  const __m256d p = _mm256_mul_pd(_mm256_cvtps_pd(av), _mm256_cvtps_pd(bv));
  __m128d lo = _mm256_castpd256_pd128(p), hi = _mm256_extractf128_pd(p, 1);
  __m128d sum;
  if constexpr (N == 3) {
    const auto p1 = _mm_unpackhi_pd(lo, lo);
    lo = _mm_add_sd(lo, hi); sum = _mm_add_sd(lo, p1);
  } else {
    lo = _mm_add_pd(lo, hi); sum = _mm_add_sd(lo, _mm_unpackhi_pd(lo, lo));
  }
  const __m128 rounded = _mm_cvtsd_ss(_mm_setzero_ps(), sum);
  uint32_t bits = uint32_t(_mm_cvtsi128_si32(_mm_castps_si128(rounded)));
  const uint64_t dbits = uint64_t(_mm_cvtsi128_si64(_mm_castpd_si128(sum)));
  if ((bits & 0x7F800000u) == 0x7F800000u && ((dbits >> 52) & 0x7FF) != 0x7FF) bits = 0x7FC00000;
  _mm_setcsr(saved); return splat(bits);
}
__declspec(noinline) std::array<uint16_t, 4> half4(PPCVRegister input) {
  // x64_seq_vector.cc emit_fast_f16_pack, before lane permutation.
  const auto src = _mm_load_si128(reinterpret_cast<const __m128i*>(input.u32));
  auto value = _mm_add_epi32(src, _mm_set1_epi32(0x08000FFF));
  value = _mm_add_epi32(value, _mm_and_si128(_mm_srli_epi32(src, 13), _mm_set1_epi32(1)));
  auto magnitude = _mm_and_si128(src, _mm_set1_epi32(0x7FFFFFFF));
  const auto in_range = _mm_cmpgt_epi32(_mm_set1_epi32(0x47FFE000), magnitude);
  value = _mm_srli_epi32(value, 13);
  magnitude = _mm_add_epi32(magnitude, _mm_set1_epi32(int(0xC7800000u)));
  const auto normal = _mm_cmpeq_epi32(magnitude, _mm_min_epu32(magnitude, _mm_set1_epi32(0x0F7FDFFF)));
  value = _mm_and_si128(value, _mm_and_si128(normal, _mm_set1_epi32(0x7FFF)));
  value = _mm_castps_si128(_mm_blendv_ps(_mm_castsi128_ps(_mm_set1_epi32(0x7FFF)), _mm_castsi128_ps(value), _mm_castsi128_ps(in_range)));
  value = _mm_or_si128(value, _mm_and_si128(_mm_srli_epi32(src, 16), _mm_set1_epi32(0x8000)));
  alignas(16) uint32_t result[4]; _mm_store_si128(reinterpret_cast<__m128i*>(result), value);
  return {uint16_t(result[0]), uint16_t(result[1]), uint16_t(result[2]), uint16_t(result[3])};
}
}  // namespace reference

__declspec(noinline) static float add_scalar(float a, float b) { return a + b; }
__declspec(noinline) static float add_vector_lane(float a, float b) {
  return simde_mm_cvtss_f32(simde_mm_add_ps(simde_mm_set1_ps(a), simde_mm_set1_ps(b)));
}

int main(int argc, char** argv) {
  const bool require_baseline_parity = argc > 1 && std::string(argv[1]) == "--require-baseline-parity";
  const unsigned original = _mm_getcsr(); _mm_setcsr(0x1F80);

  const auto golden = guest(0x3F800000, 0x3FC00000, 0x3F8CCCCD, 0x3FF33333);
  const auto expected_golden = guest(0x40000000, 0x40700000, 0x4013D70B, 0x40B051EB);
  observe("xenia_vmaddfp_1_golden", actual::vmadd(golden, golden, golden), candidate::vmadd(golden, golden, golden), expected_golden, true);
  check(equal(reference::vmadd(golden, golden, golden), expected_golden));
  auto a = splat(0x3F800001), b = splat(0x3F7FFFFE), c = splat(0xBF800000);
  observe("vmadd_cancellation", actual::vmadd(a,b,c), candidate::vmadd(a,b,c), splat(0xA8800000), true);
  a = splat(0x7F7FFFFF); b = splat(0x40000000); c = splat(0xFF7FFFFF);
  observe("vmadd_intermediate_overflow", actual::vmadd(a,b,c), candidate::vmadd(a,b,c), a, true);
  a = splat(0x00800000); b = splat(0x3F000000); c = a;
  observe("vmadd_intermediate_underflow", actual::vmadd(a,b,c), candidate::vmadd(a,b,c), splat(0x00C00000), true);
  a = splat(0x00000001); b = splat(0x3F800000); c = splat(0);
  observe("vmadd_denormal_input_flush_control", actual::vmadd(a,b,c), candidate::vmadd(a,b,c), splat(0));

  a = guest(0x3F800000,0x3FC00000,0x3F8CCCCD,0x01020304);
  b = guest(0x40000000,0x40700000,0x4013D70A,0x01020304);
  observe("xenia_vmsum3_golden", actual::dot3(a,b), candidate::dot<3>(a,b), splat(0x4122A7F0));
  a = guest(0x4B800000,0x3F800000,0xCB800000,0x7F800000); b = splat(0x3F800000);
  observe("dot3_accumulation_cancellation_and_ignored_w", actual::dot3(a,b), candidate::dot<3>(a,b), splat(0x3F800000), true);
  a = guest(0x4B800000,0x3F800000,0xCB800000,0x3F800000);
  observe("dot4_accumulation_cancellation", actual::dot4(a,b), candidate::dot<4>(a,b), splat(0x40000000), true);
  a = guest(0x7F7FFFFF,0,0,0); b = guest(0x40000000,0,0,0);
  observe("dot3_finite_overflow_maps_qnan", actual::dot3(a,b), candidate::dot<3>(a,b), splat(0x7FC00000), true);
  a = guest(0x80800000,0,0,0); b = guest(0x3F000000,0,0,0);
  observe("xenia_dot3_negative_denormal_output", actual::dot3(a,b), candidate::dot<3>(a,b), splat(0x80000000), true);
  observe("xenia_dot4_negative_denormal_output", actual::dot4(a,b), candidate::dot<4>(a,b), splat(0x80000000), true);
  a = guest(0x7F800000,0,0,0); b = guest(0x3F800000,0,0,0);
  observe("dot3_input_infinity_preserved_control", actual::dot3(a,b), candidate::dot<3>(a,b), splat(0x7F800000));

  const auto sentinel = splat(0xCDCDCDCD);
  a = guest(0x3FC00000,0xBFC00000,0x42A23EC8,0x403DB757);
  observe("half2_distinct_sign_control", actual::half2_distinct(a,sentinel), candidate::pack_half(sentinel,a,3,1,3), guest(0x3E00BE00,0xCDCDCDCD,0xCDCDCDCD,0xCDCDCDCD));
  a = guest(0x47800000,0x38000000,0,0);
  observe("half2_extended_range_and_denormal_flush", actual::half2_distinct(a,sentinel), candidate::pack_half(sentinel,a,3,1,3), guest(0x7C000000,0xCDCDCDCD,0xCDCDCDCD,0xCDCDCDCD), true);
  a = guest(0xBF800000,0x3F000000,0x3F800000,0xC0000000);
  observe("half4_alias_loses_first_negative_sign", actual::half4_alias(a), candidate::pack_half(a,a,5,2,2), guest(0xBC003800,0x3C00C000,0x3F800000,0xC0000000), true);
  a = guest(0x3F803000,0x3F801000,0xBF803000,0xBF801000);
  observe("half4_round_ties_to_even", actual::half4_alias(a), candidate::pack_half(a,a,5,2,2), guest(0x3C023C00,0xBC02BC00,0xBF803000,0xBF801000), true);
  a = guest(0x3F800000,0x40000000,0x40400000,0x40800000);
  observe("half2_alias_reads_overwritten_lane_and_ignores_mask", actual::half2_alias(a), candidate::pack_half(a,a,3,2,2), guest(0,0x3C004000,0x40400000,0x40800000), true);

  PPCVRegister pa{}, pb{}, packed_expected{};
  for (unsigned i = 0; i < 8; ++i) {
    pa.u16[i] = uint16_t(i+1); pb.u16[i] = uint16_t(101+i);
    packed_expected.u8[8+i] = uint8_t(i+1); packed_expected.u8[i] = uint8_t(101+i);
  }
  observe("vpkuhus_alias_reads_overwritten_halfwords", actual::pack_unsigned_alias(pa,pb), candidate::pack_unsigned_halfwords(pa,pb), packed_expected, true);
  for (unsigned i = 0; i < 8; ++i) pa.u16[i] = pb.u16[i] = uint16_t(0x8000+i);
  observe("vpkuhus_unsigned_saturation_control", actual::pack_unsigned_alias(pa,pb), candidate::pack_unsigned_halfwords(pa,pb), splat(0xFFFFFFFF));

  observe64("fctidz_exact_positive_2_to_63", uint64_t(actual::fctidz(0x1p63)), uint64_t(candidate::fctidz(0x1p63)), 0x7FFFFFFFFFFFFFFF, true);
  observe64("fctidz_just_below_2_to_63_control", uint64_t(actual::fctidz(0x1.fffffffffffffp62)), uint64_t(candidate::fctidz(0x1.fffffffffffffp62)), 0x7FFFFFFFFFFFFC00);
  observe64("fctidz_negative_2_to_63_control", uint64_t(actual::fctidz(-0x1p63)), uint64_t(candidate::fctidz(-0x1p63)), 0x8000000000000000);
  observe64("fctidz_nan_control", uint64_t(actual::fctidz(std::bit_cast<double>(0x7FF8000000000000ull))), uint64_t(candidate::fctidz(std::bit_cast<double>(0x7FF8000000000000ull))), 0x8000000000000000);

  // Scalar mode must work independently of VMX. Use the real installed SDK
  // FPSCR methods and exact generated frsp instruction under all four modes.
  unsigned scalar_control_passes = 0;
  for (unsigned mode = 0; mode != 4; ++mode) {
    _mm_setcsr(0x1F80);
    PPCFPSCRRegister fpscr{}; fpscr.InitHost(); fpscr.storeFromGuest(mode);
    const uint32_t expected = mode == 2 ? 0x3F800001 : 0x3F800000;
    const uint32_t result = fbits(float(actual::frsp(0x1.000001p0)));
    check(result == expected); scalar_control_passes += result == expected;
  }
  _mm_setcsr(0x1F80);
  PPCFPSCRRegister fpscr{}; fpscr.InitHost(); fpscr.storeFromGuest(2);
  fpscr.enableFlushModeUnconditional();
  const uint32_t baseline_vmx_up = fbits(add_vector_lane(1.0f,0x1p-24f));
  uint32_t scoped_vmx;
  const unsigned before = _mm_getcsr();
  { candidate::VmxScope scope; scoped_vmx = fbits(add_vector_lane(1.0f,0x1p-24f)); }
  check(_mm_getcsr() == before);
  observe64("vmx_must_ignore_scalar_upward_rounding", baseline_vmx_up, scoped_vmx, 0x3F800000, true);
  fpscr.disableFlushModeUnconditional();
  check(fbits(add_scalar(1.0f,0x1p-24f)) == 0x3F800001);
  _mm_setcsr(0x1F80);

  // Deterministic differential checks cover operation ordering / packing
  // permutations independently of the hand-selected counterexamples.
  uint32_t state = 0xC0D30003;
  auto rng = [&]() { state ^= state << 13; state ^= state >> 17; state ^= state << 5; return state; };
  unsigned half_comparisons = 0, dot_comparisons = 0, fma_comparisons = 0;
  for (unsigned sample = 0; sample != 5000; ++sample) {
    PPCVRegister va{}, vb{}, vc{};
    for (unsigned lane = 0; lane != 4; ++lane) va.u32[lane] = rng();
    const auto packed_reference = reference::half4(va);
    for (unsigned lane = 0; lane != 4; ++lane) {
      check(candidate::xenos_half(va.f32[lane],true) == packed_reference[lane]); ++half_comparisons;
      // Finite values in a broad exponent range avoid ambiguous NaN payloads.
      va.u32[lane] = (rng() & 0x807FFFFFu) | ((rng() % 240u + 7u) << 23);
      vb.u32[lane] = (rng() & 0x807FFFFFu) | ((rng() % 240u + 7u) << 23);
      vc.u32[lane] = (rng() & 0x807FFFFFu) | ((rng() % 240u + 7u) << 23);
    }
    check(equal(candidate::dot<3>(va,vb),reference::dot<3>(va,vb))); ++dot_comparisons;
    check(equal(candidate::dot<4>(va,vb),reference::dot<4>(va,vb))); ++dot_comparisons;
    check(equal(candidate::vmadd(va,vb,vc),reference::vmadd(va,vb,vc))); ++fma_comparisons;
  }
  _mm_setcsr(original);
  std::printf("{\"summary\":true,\"assertions\":%u,\"assertion_failures\":%u,\"counterexample_cases\":%u,\"scalar_rounding_controls_passed\":%u,\"half_lane_differential_comparisons\":%u,\"dot_vector_differential_comparisons\":%u,\"fma_vector_differential_comparisons\":%u,\"baseline_parity_required\":%s,\"game_executed\":false,\"fps_validated\":false}\n",
              assertions, errors, mismatches, scalar_control_passes, half_comparisons, dot_comparisons, fma_comparisons, require_baseline_parity ? "true":"false");
  return errors ? 1 : (require_baseline_parity && mismatches ? 2 : 0);
}
