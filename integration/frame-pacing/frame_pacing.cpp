#include "frame_pacing.h"

#ifndef _WIN32
#error The native frame-pacing implementation requires Windows QPC.
#endif

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>

#include <immintrin.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <limits>

namespace cod3::frame_pacing {
namespace {

constexpr uint64_t kDefaultSpinDivisor = 2000;
constexpr uint64_t kSleepDivisor = 1000;

bool QuerySystemQpc(void*, uint64_t* value_out) noexcept {
  if (value_out == nullptr) {
    return false;
  }
  LARGE_INTEGER value{};
  if (!QueryPerformanceCounter(&value) || value.QuadPart < 0) {
    return false;
  }
  *value_out = static_cast<uint64_t>(value.QuadPart);
  return true;
}

bool WaitSystemQpc(void*, uint64_t deadline_qpc, uint64_t frequency_hz,
                   uint64_t spin_margin_ticks) noexcept {
  if (frequency_hz == 0) {
    return false;
  }

  const uint64_t default_spin =
      (std::max)(uint64_t{1}, frequency_hz / kDefaultSpinDivisor);
  const uint64_t spin_margin =
      spin_margin_ticks == 0 ? default_spin : spin_margin_ticks;
  const uint64_t sleep_threshold =
      (std::max)(uint64_t{1}, frequency_hz / kSleepDivisor);
  const uint64_t sleep_boundary =
      spin_margin > (std::numeric_limits<uint64_t>::max)() - sleep_threshold
          ? (std::numeric_limits<uint64_t>::max)()
          : spin_margin + sleep_threshold;

  for (;;) {
    uint64_t now_qpc = 0;
    if (!QuerySystemQpc(nullptr, &now_qpc)) {
      return false;
    }
    if (now_qpc >= deadline_qpc) {
      return true;
    }

    const uint64_t remaining = deadline_qpc - now_qpc;
    if (remaining > sleep_boundary) {
      // The final bounded interval is handled by SwitchToThread / pause, so
      // Sleep(1) cannot be the source of a long-term 120-Hz drift.
      Sleep(1);
    } else if (remaining > spin_margin) {
      SwitchToThread();
    } else {
      _mm_pause();
    }
  }
}

bool IsEnableValue(const char* value) noexcept {
  if (value == nullptr) {
    return false;
  }
  return std::strcmp(value, "1") == 0 || std::strcmp(value, "true") == 0 ||
         std::strcmp(value, "TRUE") == 0 || std::strcmp(value, "on") == 0 ||
         std::strcmp(value, "ON") == 0 || std::strcmp(value, "120") == 0;
}

void SaturatingAdd(uint64_t& value, uint64_t addend) noexcept {
  constexpr uint64_t kMax = (std::numeric_limits<uint64_t>::max)();
  if (addend > kMax - value) {
    value = kMax;
  } else {
    value += addend;
  }
}

}  // namespace

ClockSource MakeSystemQpcClock() noexcept {
  LARGE_INTEGER frequency{};
  if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0) {
    return {};
  }
  return ClockSource{nullptr, static_cast<uint64_t>(frequency.QuadPart),
                     &QuerySystemQpc, &WaitSystemQpc};
}

Config LoadConfigFromEnvironment() noexcept {
  Config config{};
  char value[16]{};
  size_t value_length = 0;
  if (getenv_s(&value_length, value, sizeof(value), "COD3_FRAME_PACING_120") ==
          0 &&
      value_length != 0) {
    config.enabled = IsEnableValue(value);
  }
  return config;
}

Scheduler::Scheduler(Config config) noexcept : config_(config) {}

void Scheduler::SetEnabled(bool enabled) noexcept {
  if (config_.enabled == enabled) {
    return;
  }
  config_.enabled = enabled;
  Reset();
}

void Scheduler::Reset() noexcept {
  armed_ = false;
  have_last_observed_ = false;
  frequency_hz_ = 0;
  period_base_ticks_ = 0;
  period_remainder_ = 0;
  fractional_carry_ = 0;
  next_deadline_qpc_ = 0;
  last_observed_qpc_ = 0;
  have_last_render_id_ = false;
  last_render_id_ = 0;
  telemetry_ = {};
}

bool Scheduler::ValidateFrequency(uint64_t frequency_hz) const noexcept {
  return config_.target_hz != 0 && frequency_hz >= config_.target_hz;
}

bool Scheduler::AdvanceOne() noexcept {
  if (period_base_ticks_ == 0 || config_.target_hz == 0) {
    return false;
  }

  uint64_t increment = period_base_ticks_;
  uint64_t carry = fractional_carry_ + period_remainder_;
  if (carry >= config_.target_hz) {
    ++increment;
    carry -= config_.target_hz;
  }
  if (increment == 0 || next_deadline_qpc_ >
                              (std::numeric_limits<uint64_t>::max)() -
                                  increment) {
    return false;
  }
  next_deadline_qpc_ += increment;
  fractional_carry_ = carry;
  return true;
}

void Scheduler::Reanchor(uint64_t now_qpc, uint64_t frequency_hz,
                         bool count_telemetry) noexcept {
  armed_ = true;
  frequency_hz_ = frequency_hz;
  period_base_ticks_ = frequency_hz / config_.target_hz;
  period_remainder_ = frequency_hz % config_.target_hz;
  fractional_carry_ = 0;
  next_deadline_qpc_ = now_qpc;
  if (!AdvanceOne()) {
    armed_ = false;
  }
  if (count_telemetry) {
    ++telemetry_.reanchors;
  }
}

void Scheduler::ObserveFrameIdentity(FrameIdentity frame,
                                     GateResult& result) noexcept {
  if (!frame.valid) {
    ++telemetry_.unknown_frame_ids;
    have_last_render_id_ = false;
    return;
  }
  if (have_last_render_id_ && last_render_id_ == frame.render_id) {
    result.duplicate_frame = true;
    ++telemetry_.duplicate_frames;
  }
  have_last_render_id_ = true;
  last_render_id_ = frame.render_id;
}

GateResult Scheduler::BeforePresent(FrameIdentity frame,
                                    const ClockSource& clock) noexcept {
  GateResult result{};
  if (!config_.enabled) {
    result.status = GateStatus::Disabled;
    return result;
  }

  ++telemetry_.gated_present_calls;
  ObserveFrameIdentity(frame, result);

  if (config_.target_hz == 0) {
    result.status = GateStatus::InvalidConfiguration;
    return result;
  }
  if (clock.frequency_hz == 0 || clock.now == nullptr) {
    ++telemetry_.qpc_failures;
    result.status = GateStatus::ClockUnavailable;
    armed_ = false;
    return result;
  }

  uint64_t observed_before_wait = 0;
  if (!clock.now(clock.user, &observed_before_wait)) {
    ++telemetry_.qpc_failures;
    result.status = GateStatus::ClockUnavailable;
    armed_ = false;
    return result;
  }
  result.observed_qpc = observed_before_wait;

  if (!ValidateFrequency(clock.frequency_hz)) {
    result.status = GateStatus::InvalidConfiguration;
    return result;
  }

  if (!armed_) {
    Reanchor(observed_before_wait, clock.frequency_hz, false);
    if (!armed_) {
      ++telemetry_.qpc_failures;
      result.status = GateStatus::ClockUnavailable;
      return result;
    }
    result.first_frame = true;
    result.status = GateStatus::Ready;
    ++telemetry_.first_present_calls;
    have_last_observed_ = true;
    last_observed_qpc_ = observed_before_wait;
    return result;
  }

  if (clock.frequency_hz != frequency_hz_ ||
      (have_last_observed_ && observed_before_wait < last_observed_qpc_)) {
    Reanchor(observed_before_wait, clock.frequency_hz, true);
    result.reanchored = true;
    result.status = armed_ ? GateStatus::Ready : GateStatus::ClockUnavailable;
    if (!armed_) {
      ++telemetry_.qpc_failures;
    }
    have_last_observed_ = true;
    last_observed_qpc_ = observed_before_wait;
    return result;
  }

  const uint64_t scheduled_deadline = next_deadline_qpc_;
  result.scheduled_deadline_qpc = scheduled_deadline;
  uint64_t observed = observed_before_wait;
  if (observed < scheduled_deadline) {
    result.waited = true;
    ++telemetry_.waited_present_calls;
    if (clock.wait_until == nullptr ||
        !clock.wait_until(clock.user, scheduled_deadline, clock.frequency_hz,
                          config_.spin_margin_ticks)) {
      ++telemetry_.wait_failures;
      ++telemetry_.reanchors;
      armed_ = false;
      result.status = GateStatus::ClockUnavailable;
      have_last_observed_ = true;
      last_observed_qpc_ = observed_before_wait;
      return result;
    }
    uint64_t observed_after_wait = 0;
    if (!clock.now(clock.user, &observed_after_wait)) {
      ++telemetry_.qpc_failures;
      armed_ = false;
      result.status = GateStatus::ClockUnavailable;
      return result;
    }
    observed = observed_after_wait;
    result.observed_qpc = observed;
    if (observed >= observed_before_wait) {
      result.wait_ticks = observed - observed_before_wait;
      SaturatingAdd(telemetry_.total_wait_ticks, result.wait_ticks);
      telemetry_.max_wait_ticks =
          (std::max)(telemetry_.max_wait_ticks, result.wait_ticks);
    }
    result.wait_succeeded = observed >= scheduled_deadline;
    if (!result.wait_succeeded) {
      ++telemetry_.wait_failures;
      ++telemetry_.reanchors;
      armed_ = false;
      result.status = GateStatus::ClockUnavailable;
      have_last_observed_ = true;
      last_observed_qpc_ = observed;
      return result;
    }
  }

  if (observed > scheduled_deadline) {
    result.status = GateStatus::Late;
    result.lateness_ticks = observed - scheduled_deadline;
    telemetry_.max_lateness_ticks =
        (std::max)(telemetry_.max_lateness_ticks, result.lateness_ticks);
    ++telemetry_.late_present_calls;
    result.missed_deadlines = 1;

    // Advance the rational schedule past the observed point. The cap prevents
    // a long suspend or debugger break from making the next Present spend an
    // unbounded amount of time catching up. Such a reanchor is visible in
    // telemetry and does not alter guest time.
    uint64_t caught_up = 0;
    bool schedule_valid = AdvanceOne();
    while (schedule_valid && next_deadline_qpc_ < observed &&
           caught_up < kMaxCatchUpPeriods) {
      ++result.missed_deadlines;
      ++caught_up;
      schedule_valid = AdvanceOne();
    }
    if (schedule_valid && next_deadline_qpc_ == observed) {
      schedule_valid = AdvanceOne();
    }
    if (!schedule_valid ||
        (next_deadline_qpc_ < observed &&
         caught_up >= kMaxCatchUpPeriods)) {
      ++telemetry_.catch_up_limited;
      Reanchor(observed, clock.frequency_hz, true);
      result.reanchored = true;
    }
    SaturatingAdd(telemetry_.missed_deadlines, result.missed_deadlines);
  } else {
    result.status = GateStatus::Ready;
    ++telemetry_.scheduled_on_time_present_calls;
    if (!AdvanceOne()) {
      ++telemetry_.qpc_failures;
      Reanchor(observed, clock.frequency_hz, true);
      result.reanchored = true;
    }
  }

  result.observed_qpc = observed;
  have_last_observed_ = true;
  last_observed_qpc_ = observed;
  return result;
}

}  // namespace cod3::frame_pacing
