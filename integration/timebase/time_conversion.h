#pragma once

// Integer conversion helpers used by the timebase differential tests.  These
// model the rational conversion used by both the pinned Xenia clock and the
// ReXGlue clock.  They are not a second runtime clock and must not be used to
// replace QueryReXGlueGuestTicks().

#include <cstdint>
#include <limits>

#include "rexglue_xenon_timebase.h"

namespace cod3::timebase::conversion {

struct Ratio {
  uint64_t numerator;
  uint64_t denominator;
};

struct WideProduct {
  uint64_t high;
  uint64_t low;
};

// Form the exact 128-bit product from 32-bit limbs.  Keeping this helper in
// the adapter avoids a dependency on compiler runtime helpers such as
// __udivti3 when the Windows binary is linked with the SDK's MSVC CRT model.
constexpr WideProduct MultiplyWide(uint64_t left, uint64_t right) noexcept {
  constexpr uint64_t kLimbMask = 0xFFFF'FFFFull;
  const uint64_t left_low = left & kLimbMask;
  const uint64_t left_high = left >> 32;
  const uint64_t right_low = right & kLimbMask;
  const uint64_t right_high = right >> 32;

  uint64_t term = left_low * right_low;
  const uint64_t word3 = term & kLimbMask;
  uint64_t carry = term >> 32;

  term = left_high * right_low + carry;
  const uint64_t word2 = term & kLimbMask;
  const uint64_t word1 = term >> 32;

  term = left_low * right_high + word2;
  carry = term >> 32;

  const uint64_t high = left_high * right_high + word1 + carry;
  const uint64_t low = (term << 32) + word3;
  return {high, low};
}

// Divide a 128-bit product by a 64-bit denominator.  The quotient is
// saturated at UINT64_MAX because time conversion is a boundary at which a
// wrap would be much harder to diagnose than a bounded result.
constexpr uint64_t DivideWideSaturating(WideProduct product,
                                        uint64_t denominator) noexcept {
  if (denominator == 0) {
    return 0;
  }

  uint64_t remainder = 0;
  uint64_t quotient_high = 0;
  uint64_t quotient_low = 0;
  for (int bit = 127; bit >= 0; --bit) {
    const uint64_t incoming =
        bit >= 64 ? ((product.high >> (bit - 64)) & 1ull)
                  : ((product.low >> bit) & 1ull);
    // 2 * remainder + incoming >= denominator, written without an
    // overflowing intermediate.  remainder is always below denominator.
    const uint64_t threshold =
        incoming == 0 ? denominator / 2 + (denominator & 1ull)
                      : denominator / 2;
    if (remainder >= threshold) {
      remainder = (remainder << 1) | incoming;
      remainder -= denominator;
      if (bit >= 64) {
        quotient_high |= 1ull << (bit - 64);
      } else {
        quotient_low |= 1ull << bit;
      }
    } else {
      remainder = (remainder << 1) | incoming;
    }
  }

  if (quotient_high != 0) {
    return (std::numeric_limits<uint64_t>::max)();
  }
  return quotient_low;
}

constexpr uint64_t GreatestCommonDivisor(uint64_t left,
                                         uint64_t right) noexcept {
  while (right != 0) {
    const uint64_t remainder = left % right;
    left = right;
    right = remainder;
  }
  return left;
}

constexpr Ratio MakeHostToGuestRatio(uint64_t guest_frequency_hz,
                                     uint64_t host_frequency_hz) noexcept {
  if (guest_frequency_hz == 0 || host_frequency_hz == 0) {
    return {0, 1};
  }
  const uint64_t divisor = GreatestCommonDivisor(guest_frequency_hz,
                                                 host_frequency_hz);
  return {guest_frequency_hz / divisor, host_frequency_hz / divisor};
}

// The pinned implementations multiply before dividing.  Use a 128-bit
// intermediate so the test oracle remains exact for large QPC deltas and
// saturates instead of wrapping if a caller supplies an unrepresentable span.
constexpr uint64_t ApplyRatioSaturating(uint64_t value,
                                        Ratio ratio) noexcept {
  if (ratio.denominator == 0 || ratio.numerator == 0 || value == 0) {
    return 0;
  }
  return DivideWideSaturating(MultiplyWide(value, ratio.numerator),
                              ratio.denominator);
}

constexpr uint64_t HostTicksToGuestTicks(
    uint64_t host_ticks,
    uint64_t host_frequency_hz,
    uint64_t guest_frequency_hz = kXbox360GuestTickFrequencyHz) noexcept {
  return ApplyRatioSaturating(
      host_ticks, MakeHostToGuestRatio(guest_frequency_hz, host_frequency_hz));
}

constexpr uint64_t GuestTicksToMilliseconds(uint64_t guest_ticks,
                                            uint64_t guest_frequency_hz =
                                                kXbox360GuestTickFrequencyHz) noexcept {
  return ApplyRatioSaturating(guest_ticks,
                              MakeHostToGuestRatio(1000, guest_frequency_hz));
}

constexpr uint64_t GuestTicksToNanoseconds(uint64_t guest_ticks,
                                           uint64_t guest_frequency_hz =
                                               kXbox360GuestTickFrequencyHz) noexcept {
  return ApplyRatioSaturating(guest_ticks,
                              MakeHostToGuestRatio(1'000'000'000,
                                                   guest_frequency_hz));
}

}  // namespace cod3::timebase::conversion
