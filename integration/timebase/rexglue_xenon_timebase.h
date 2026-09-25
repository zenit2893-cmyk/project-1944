#pragma once

// The XenonRecomp output uses a host-counter expression for the PPC mftb
// instruction.  This header exposes a deliberately small seam for a selected
// Xenon-generated translation unit.  The seam reads ReXGlue's guest clock and
// never reads a host counter directly.

#include <cstdint>

#include <rex/chrono/clock.h>

namespace cod3::timebase {

inline constexpr uint64_t kXbox360GuestTickFrequencyHz = 50'000'000;
inline constexpr double kNormalGuestTimeScalar = 1.0;

struct GuestClockContract {
  uint64_t guest_tick_frequency_hz;
  double guest_time_scalar;

  [[nodiscard]] constexpr bool IsCanonical() const noexcept {
    return guest_tick_frequency_hz == kXbox360GuestTickFrequencyHz &&
           guest_time_scalar == kNormalGuestTimeScalar;
  }
};

// Read-only observation of the ReXGlue clock configuration.  This function
// does not set the frequency or scalar and therefore cannot change guest time,
// vblank, or simulation cadence.
GuestClockContract ReadGuestClockContract() noexcept;

// The only production time source exposed by this adapter.  ReXGlue owns the
// host-to-guest conversion, synchronization, and configured scalar.
uint64_t QueryReXGlueGuestTicks() noexcept;

// Use this function as the lexical replacement for the generated mftb token
// when compiling one explicitly selected XenonRecomp translation unit:
//
//   #define <generated mftb token>() ::cod3::timebase::QuerySelectedXenonMftb()
//   #include "selected_xenon_generated.inl"
//   #undef <generated mftb token>
//
// The macro must stay scoped to that include.  Do not add it to a project-wide
// precompiled header or to ReXGlue-generated sources.
uint64_t QuerySelectedXenonMftb() noexcept;

}  // namespace cod3::timebase
