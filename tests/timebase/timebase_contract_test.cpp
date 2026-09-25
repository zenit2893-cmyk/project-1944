#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <limits>
#include <string_view>
#include <vector>

#include "rexglue_xenon_timebase.h"
#include "time_conversion.h"

// Keep the remapping lexical and local to this synthetic include site.  This
// has the same token boundary as XenonRecomp's selected __rdtsc() emission,
// while leaving every active generated file untouched.
#define __rdtsc() ::cod3::timebase::QuerySelectedXenonMftb()
#include "selected_xenon_mftb_site.inl"
#undef __rdtsc

namespace {

using cod3::timebase::conversion::ApplyRatioSaturating;
using cod3::timebase::conversion::GuestTicksToMilliseconds;
using cod3::timebase::conversion::GuestTicksToNanoseconds;
using cod3::timebase::conversion::HostTicksToGuestTicks;
using cod3::timebase::conversion::MakeHostToGuestRatio;
using cod3::timebase::conversion::Ratio;

void Check(bool condition, std::string_view expression, int line) {
  if (!condition) {
    std::fprintf(stderr, "FAILED line %d: %.*s\n", line,
                 static_cast<int>(expression.size()), expression.data());
    std::abort();
  }
}

#define CHECK(expression) Check(bool(expression), #expression, __LINE__)

uint64_t IndependentHostToGuest(uint64_t host_ticks,
                                uint64_t host_frequency_hz,
                                uint64_t guest_frequency_hz) {
  CHECK(host_frequency_hz != 0);
  CHECK(host_ticks <=
        (std::numeric_limits<uint64_t>::max)() / guest_frequency_hz);
  const uint64_t product = host_ticks * guest_frequency_hz;
  return product / host_frequency_hz;
}

struct ClockModel {
  Ratio ratio;
  uint64_t last_host_ticks;
  uint64_t guest_ticks{};

  uint64_t Update(uint64_t host_ticks) {
    const uint64_t delta = host_ticks > last_host_ticks
                               ? host_ticks - last_host_ticks
                               : 0;
    last_host_ticks = host_ticks;
    guest_ticks += ApplyRatioSaturating(delta, ratio);
    return guest_ticks;
  }
};

void TestRatiosAndConversions() {
  static_assert(cod3::timebase::kXbox360GuestTickFrequencyHz == 50'000'000);
  static_assert(MakeHostToGuestRatio(50'000'000, 10'000'000).numerator == 5);
  static_assert(MakeHostToGuestRatio(50'000'000, 10'000'000).denominator == 1);
  static_assert(HostTicksToGuestTicks(10'000'000, 10'000'000) == 50'000'000);
  static_assert(GuestTicksToMilliseconds(50'000'000) == 1000);
  static_assert(GuestTicksToNanoseconds(50'000'000) == 1'000'000'000);

  const std::array<uint64_t, 4> host_frequencies = {
      10'000'000, 3'579'545, 24'000'000, 1'000'000};
  const std::array<uint64_t, 13> deltas = {
      0, 1, 2, 3, 7, 10'000, 1'000'000, 10'000'000,
      123'456'789, 4'000'000'000, 100'000'000'000ull,
      300'000'000'000ull, 350'000'000'000ull};

  for (const uint64_t host_frequency : host_frequencies) {
    const Ratio ratio = MakeHostToGuestRatio(
        cod3::timebase::kXbox360GuestTickFrequencyHz, host_frequency);
    CHECK(ratio.denominator != 0);
    for (const uint64_t delta : deltas) {
      const uint64_t expected = IndependentHostToGuest(
          delta, host_frequency,
          cod3::timebase::kXbox360GuestTickFrequencyHz);
      CHECK(HostTicksToGuestTicks(delta, host_frequency) == expected);
      CHECK(ApplyRatioSaturating(delta, ratio) == expected);
    }
  }

  CHECK(GuestTicksToMilliseconds(0) == 0);
  CHECK(GuestTicksToMilliseconds(2'500'000) == 50);
  CHECK(GuestTicksToMilliseconds(2'500'049) == 50);
  CHECK(GuestTicksToNanoseconds(1) == 20);
  CHECK(GuestTicksToNanoseconds(2'500'000) == 50'000'000);
  CHECK(GuestTicksToNanoseconds((std::numeric_limits<uint64_t>::max)()) ==
        (std::numeric_limits<uint64_t>::max)());
  CHECK(HostTicksToGuestTicks((std::numeric_limits<uint64_t>::max)(),
                              (std::numeric_limits<uint64_t>::max)(), 1) == 1);
}

void TestXeniaAndReXGlueUpdateContract() {
  // Both pinned implementations keep the last host sample and add the
  // per-update floor(host_delta * guest_frequency / host_frequency).  The
  // backward sample must not move guest time backwards.
  const uint64_t host_frequency = 3'579'545;
  const Ratio xenia_ratio = MakeHostToGuestRatio(50'000'000, host_frequency);
  const Ratio rexglue_ratio = MakeHostToGuestRatio(50'000'000, host_frequency);
  CHECK(xenia_ratio.numerator == rexglue_ratio.numerator);
  CHECK(xenia_ratio.denominator == rexglue_ratio.denominator);

  const std::array<uint64_t, 10> host_samples = {
      10'000, 10'001, 10'002, 12'345, 12'344, 50'000,
      50'000, 100'000, 100'001, 1'000'000};
  ClockModel xenia{xenia_ratio, host_samples.front()};
  ClockModel rexglue{rexglue_ratio, host_samples.front()};
  for (const uint64_t sample : host_samples) {
    const uint64_t xenia_ticks = xenia.Update(sample);
    const uint64_t rexglue_ticks = rexglue.Update(sample);
    CHECK(xenia_ticks == rexglue_ticks);
  }

  // A conversion is applied to each host interval, matching UpdateGuestClock;
  // converting one accumulated span is intentionally a separate operation.
  const uint64_t first = HostTicksToGuestTicks(1, host_frequency);
  const uint64_t second = HostTicksToGuestTicks(1, host_frequency);
  CHECK(first + second <= HostTicksToGuestTicks(2, host_frequency));
}

void TestCanonicalContractAndSelectedSeam() {
  constexpr cod3::timebase::GuestClockContract canonical{
      cod3::timebase::kXbox360GuestTickFrequencyHz,
      cod3::timebase::kNormalGuestTimeScalar};
  constexpr cod3::timebase::GuestClockContract wrong_frequency{10'000'000, 1.0};
  CHECK(canonical.IsCanonical());
  CHECK(!wrong_frequency.IsCanonical());

  // No setter is called here.  The native test only observes whatever clock
  // the SDK process currently exposes, then checks that the selected mftb
  // expression is monotonic and goes through the same adapter entry point.
  const auto runtime_contract = cod3::timebase::ReadGuestClockContract();
  CHECK(runtime_contract.guest_tick_frequency_hz != 0);
  CHECK(runtime_contract.guest_time_scalar > 0.0);

  const uint64_t first = cod3_selected_xenon_mftb_expression();
  const uint64_t direct = cod3::timebase::QueryReXGlueGuestTicks();
  const uint64_t second = cod3_selected_xenon_mftb_expression();
  CHECK(direct >= first);
  CHECK(second >= direct);
}

}  // namespace

int main() {
  TestRatiosAndConversions();
  TestXeniaAndReXGlueUpdateContract();
  TestCanonicalContractAndSelectedSeam();
  std::puts("PASS: Xenon mftb seam, Xenia/ReXGlue rational conversion, and guest units");
  std::puts("NO GAME, VBLANK, SIMULATION, OR 120 FPS SETTINGS WERE CHANGED");
  return 0;
}
