#include "rexglue_xenon_timebase.h"

namespace cod3::timebase {

GuestClockContract ReadGuestClockContract() noexcept {
  return {rex::chrono::Clock::guest_tick_frequency(),
          rex::chrono::Clock::guest_time_scalar()};
}

uint64_t QueryReXGlueGuestTicks() noexcept {
  return rex::chrono::Clock::QueryGuestTickCount();
}

uint64_t QuerySelectedXenonMftb() noexcept {
  return QueryReXGlueGuestTicks();
}

}  // namespace cod3::timebase
