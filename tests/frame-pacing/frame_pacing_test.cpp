#include "frame_pacing.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

using cod3::frame_pacing::ClockSource;
using cod3::frame_pacing::Config;
using cod3::frame_pacing::FrameIdentity;
using cod3::frame_pacing::GateStatus;
using cod3::frame_pacing::LoadConfigFromEnvironment;
using cod3::frame_pacing::Scheduler;

struct FakeClock {
  uint64_t now = 0;
  uint64_t wait_lateness = 0;
  uint64_t frequency = 1'000'000;
  uint32_t wait_calls = 0;
  std::vector<uint64_t> deadlines;

  static bool Now(void* user, uint64_t* out) noexcept {
    auto* clock = static_cast<FakeClock*>(user);
    if (out == nullptr) {
      return false;
    }
    *out = clock->now;
    return true;
  }

  static bool WaitUntil(void* user, uint64_t deadline, uint64_t,
                        uint64_t) noexcept {
    auto* clock = static_cast<FakeClock*>(user);
    ++clock->wait_calls;
    clock->deadlines.push_back(deadline);
    clock->now = deadline + clock->wait_lateness;
    return true;
  }

  ClockSource Source() noexcept {
    return ClockSource{this, frequency, &Now, &WaitUntil};
  }
};

void Require(bool condition, const char* expression, const char* test) {
  if (!condition) {
    std::cerr << test << ": failed: " << expression << '\n';
    std::exit(1);
  }
}

#define REQUIRE(condition) Require((condition), #condition, __func__)

void DisabledIsPassthrough() {
  Scheduler scheduler{};
  FakeClock clock;
  const auto result =
      scheduler.BeforePresent(FrameIdentity::Render(1), clock.Source());
  REQUIRE(result.status == GateStatus::Disabled);
  REQUIRE(!result.waited);
  REQUIRE(clock.wait_calls == 0);
  const auto telemetry = scheduler.telemetry();
  REQUIRE(telemetry.gated_present_calls == 0);
  REQUIRE(telemetry.duplicate_frames == 0);
}

void EnvironmentOptInIsExplicit() {
  char* saved_value = nullptr;
  size_t saved_length = 0;
  const errno_t saved_status =
      _dupenv_s(&saved_value, &saved_length, "COD3_FRAME_PACING_120");
  REQUIRE(saved_status == 0);

  REQUIRE(_putenv_s("COD3_FRAME_PACING_120", "") == 0);
  REQUIRE(!LoadConfigFromEnvironment().enabled);
  REQUIRE(_putenv_s("COD3_FRAME_PACING_120", "1") == 0);
  const auto enabled = LoadConfigFromEnvironment();
  REQUIRE(enabled.enabled);
  REQUIRE(enabled.target_hz == 120);

  if (saved_value != nullptr) {
    REQUIRE(_putenv_s("COD3_FRAME_PACING_120", saved_value) == 0);
    std::free(saved_value);
  } else {
    REQUIRE(_putenv_s("COD3_FRAME_PACING_120", "") == 0);
  }
}

void FractionalCarryDistributesQpcTicks() {
  Config config{};
  config.enabled = true;
  config.target_hz = 120;
  Scheduler scheduler(config);
  FakeClock clock;
  clock.now = 1'000;

  const auto first =
      scheduler.BeforePresent(FrameIdentity::Render(1), clock.Source());
  REQUIRE(first.status == GateStatus::Ready);
  REQUIRE(first.first_frame);

  const auto second =
      scheduler.BeforePresent(FrameIdentity::Render(2), clock.Source());
  const auto third =
      scheduler.BeforePresent(FrameIdentity::Render(3), clock.Source());
  const auto fourth =
      scheduler.BeforePresent(FrameIdentity::Render(4), clock.Source());
  REQUIRE(second.waited && second.wait_succeeded);
  REQUIRE(third.waited && third.wait_succeeded);
  REQUIRE(fourth.waited && fourth.wait_succeeded);
  REQUIRE(clock.deadlines.size() == 3);
  // 1,000,000 / 120 = 8,333 + 40/120. The 40-tick remainder is carried
  // exactly, yielding 8,333, 8,333, 8,334 over three intervals.
  REQUIRE(clock.deadlines[0] == 9'333);
  REQUIRE(clock.deadlines[1] == 17'666);
  REQUIRE(clock.deadlines[2] == 26'000);
  REQUIRE(fourth.scheduled_deadline_qpc == 17'666 + 8'334);
}

void DuplicateRenderIdsAreObservedButNeverDropped() {
  Config config{};
  config.enabled = true;
  Scheduler scheduler(config);
  FakeClock clock;

  const auto first =
      scheduler.BeforePresent(FrameIdentity::Render(42), clock.Source());
  const auto second =
      scheduler.BeforePresent(FrameIdentity::Render(42), clock.Source());
  const auto third =
      scheduler.BeforePresent(FrameIdentity::Render(43), clock.Source());
  REQUIRE(first.status == GateStatus::Ready);
  REQUIRE(second.status == GateStatus::Ready);
  REQUIRE(second.duplicate_frame);
  REQUIRE(third.status == GateStatus::Ready);
  REQUIRE(!third.duplicate_frame);
  REQUIRE(scheduler.telemetry().duplicate_frames == 1);
}

void MissedDeadlinesAreCountedAndScheduleRecovers() {
  Config config{};
  config.enabled = true;
  Scheduler scheduler(config);
  FakeClock clock;
  clock.wait_lateness = 25'000;

  scheduler.BeforePresent(FrameIdentity::Render(1), clock.Source());
  const auto late =
      scheduler.BeforePresent(FrameIdentity::Render(2), clock.Source());
  REQUIRE(late.status == GateStatus::Late);
  REQUIRE(late.lateness_ticks == 25'000);
  REQUIRE(late.missed_deadlines >= 1);
  REQUIRE(scheduler.telemetry().late_present_calls == 1);
  REQUIRE(scheduler.telemetry().missed_deadlines >= 1);

  // The scheduler advances past the delayed point instead of issuing a burst
  // of immediate calls. The next call waits for a future deadline.
  clock.wait_lateness = 0;
  const auto recovered =
      scheduler.BeforePresent(FrameIdentity::Render(3), clock.Source());
  REQUIRE(recovered.status == GateStatus::Ready);
  REQUIRE(recovered.waited);
}

void UnknownIdsBreakDuplicateChain() {
  Config config{};
  config.enabled = true;
  Scheduler scheduler(config);
  FakeClock clock;
  scheduler.BeforePresent(FrameIdentity::Render(7), clock.Source());
  scheduler.BeforePresent(FrameIdentity::Unknown(), clock.Source());
  const auto result =
      scheduler.BeforePresent(FrameIdentity::Render(7), clock.Source());
  REQUIRE(!result.duplicate_frame);
  REQUIRE(scheduler.telemetry().unknown_frame_ids == 1);
}

void InvalidClockDoesNotBlockPresent() {
  Config config{};
  config.enabled = true;
  Scheduler scheduler(config);
  const auto result = scheduler.BeforePresent(FrameIdentity::Unknown(), {});
  REQUIRE(result.status == GateStatus::ClockUnavailable);
  REQUIRE(scheduler.telemetry().qpc_failures == 1);
}

}  // namespace

int main() {
  DisabledIsPassthrough();
  EnvironmentOptInIsExplicit();
  FractionalCarryDistributesQpcTicks();
  DuplicateRenderIdsAreObservedButNeverDropped();
  MissedDeadlinesAreCountedAndScheduleRecovers();
  UnknownIdsBreakDuplicateChain();
  InvalidClockDoesNotBlockPresent();
  std::cout << "frame_pacing_native: PASS (synthetic clock; no gameplay)\n";
  return 0;
}
