#pragma once

#include <cstdint>

namespace cod3::frame_pacing {

// The scheduler only gates the native host presentation call. It deliberately
// has no guest-time, vblank, simulation, or physics interface.
constexpr uint32_t kDefaultTargetHz = 120;

struct FrameIdentity {
  bool valid = false;
  uint64_t render_id = 0;

  static constexpr FrameIdentity Unknown() noexcept { return {}; }
  static constexpr FrameIdentity Render(uint64_t id) noexcept {
    return FrameIdentity{true, id};
  }
};

using QpcNowFn = bool (*)(void* user, uint64_t* value_out) noexcept;
using QpcWaitUntilFn = bool (*)(void* user, uint64_t deadline_qpc,
                                uint64_t frequency_hz,
                                uint64_t spin_margin_ticks) noexcept;

// A clock is passed to BeforePresent so native tests can use a deterministic
// source. The production source is MakeSystemQpcClock(), which uses Windows
// QPC/QPF and never touches the guest clock.
struct ClockSource {
  void* user = nullptr;
  uint64_t frequency_hz = 0;
  QpcNowFn now = nullptr;
  QpcWaitUntilFn wait_until = nullptr;

  constexpr bool IsUsable() const noexcept {
    return frequency_hz != 0 && now != nullptr && wait_until != nullptr;
  }
};

ClockSource MakeSystemQpcClock() noexcept;

struct Config {
  // Keep this false unless the host explicitly opts in. The default path is a
  // pure presentation passthrough and performs no QPC call.
  bool enabled = false;
  uint32_t target_hz = kDefaultTargetHz;

  // Zero selects a bounded production default of approximately 0.5 ms. The
  // value is expressed in QPC ticks and is used only by the host wait loop.
  uint64_t spin_margin_ticks = 0;
};

// Reads COD3_FRAME_PACING_120. Values 1, true, on, and 120 enable the 120-Hz
// host scheduler; an absent or any other value leaves it disabled.
Config LoadConfigFromEnvironment() noexcept;

enum class GateStatus : uint8_t {
  Disabled,
  Ready,
  Late,
  InvalidConfiguration,
  ClockUnavailable,
};

struct GateResult {
  GateStatus status = GateStatus::Disabled;
  bool first_frame = false;
  bool reanchored = false;
  bool duplicate_frame = false;
  bool waited = false;
  bool wait_succeeded = false;
  uint64_t scheduled_deadline_qpc = 0;
  uint64_t observed_qpc = 0;
  uint64_t wait_ticks = 0;
  uint64_t lateness_ticks = 0;
  uint64_t missed_deadlines = 0;
};

// Counters are intentionally host-presentation counters. They must not be
// labelled as simulation ticks or used as a gameplay FPS acceptance result.
struct Telemetry {
  uint64_t gated_present_calls = 0;
  uint64_t first_present_calls = 0;
  uint64_t scheduled_on_time_present_calls = 0;
  uint64_t waited_present_calls = 0;
  uint64_t late_present_calls = 0;
  uint64_t missed_deadlines = 0;
  uint64_t duplicate_frames = 0;
  uint64_t unknown_frame_ids = 0;
  uint64_t qpc_failures = 0;
  uint64_t wait_failures = 0;
  uint64_t reanchors = 0;
  uint64_t catch_up_limited = 0;
  uint64_t total_wait_ticks = 0;
  uint64_t max_wait_ticks = 0;
  uint64_t max_lateness_ticks = 0;
};

class Scheduler final {
 public:
  explicit Scheduler(Config config = {}) noexcept;

  Scheduler(const Scheduler&) = delete;
  Scheduler& operator=(const Scheduler&) = delete;

  Config config() const noexcept { return config_; }
  bool enabled() const noexcept { return config_.enabled; }

  // Changes the opt-in state and starts a fresh native presentation schedule.
  // This does not modify any guest state or time source.
  void SetEnabled(bool enabled) noexcept;

  // Reset schedule and telemetry while retaining the current configuration.
  void Reset() noexcept;

  // Called immediately before the host IDXGISwapChain::Present boundary. It
  // may wait for a QPC deadline when enabled, but it never suppresses the
  // caller's Present call. A missing clock or wait failure therefore returns a
  // result that still permits presentation and exposes the fault in telemetry.
  GateResult BeforePresent(FrameIdentity frame,
                           const ClockSource& clock) noexcept;

  Telemetry telemetry() const noexcept { return telemetry_; }

 private:
  static constexpr uint64_t kMaxCatchUpPeriods = 4096;

  bool ValidateFrequency(uint64_t frequency_hz) const noexcept;
  bool AdvanceOne() noexcept;
  void Reanchor(uint64_t now_qpc, uint64_t frequency_hz,
                bool count_telemetry) noexcept;
  void ObserveFrameIdentity(FrameIdentity frame, GateResult& result) noexcept;

  Config config_{};
  bool armed_ = false;
  bool have_last_observed_ = false;
  uint64_t frequency_hz_ = 0;
  uint64_t period_base_ticks_ = 0;
  uint64_t period_remainder_ = 0;
  uint64_t fractional_carry_ = 0;
  uint64_t next_deadline_qpc_ = 0;
  uint64_t last_observed_qpc_ = 0;
  bool have_last_render_id_ = false;
  uint64_t last_render_id_ = 0;
  Telemetry telemetry_{};
};

}  // namespace cod3::frame_pacing
