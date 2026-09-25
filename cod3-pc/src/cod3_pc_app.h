// cod3_pc - ReXGlue Recompiled Project
//
// Customize your app by overriding virtual hooks from rex::ReXApp.

#pragma once

#include <rex/rex_app.h>
#include <rex/logging.h>
#include "candidate_observer.h"
#include "pc_controls.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <timeapi.h>

namespace cod3::host {
// The SDK's guest vblank worker and guest sleeps wait with ::Sleep/SleepEx in
// 1 ms steps, but nothing requests a 1 ms system timer. At the default
// 15.6 ms resolution vblanks arrive in bursts and frame pacing judders.
// Request 1 ms for the process lifetime and opt out of power throttling so
// Windows 11 keeps honoring it (and full CPU speed) while the game runs.
inline bool EnableHighResolutionTiming() {
  PROCESS_POWER_THROTTLING_STATE throttling{};
  throttling.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
  throttling.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED |
                           PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION;
  throttling.StateMask = 0;  // 0 = never throttle, always honor the timer request
  SetProcessInformation(GetCurrentProcess(), ProcessPowerThrottling, &throttling,
                        sizeof(throttling));
  return timeBeginPeriod(1) == TIMERR_NOERROR;
}
inline void DisableHighResolutionTiming() { timeEndPeriod(1); }
}  // namespace cod3::host

class Cod3PcApp : public rex::ReXApp {
 public:
  using rex::ReXApp::ReXApp;

  void OnPreSetup(rex::RuntimeConfig& config) override {
    (void)config;
    timer_period_set_ = cod3::host::EnableHighResolutionTiming();
    REXLOG_INFO("Host timer resolution 1 ms: {}", timer_period_set_ ? "enabled" : "FAILED");
  }

  static std::unique_ptr<rex::ui::WindowedApp> Create(
      rex::ui::WindowedAppContext& ctx) {
    return std::unique_ptr<Cod3PcApp>(new Cod3PcApp(ctx, "cod3_pc",
        PPCImageConfig));
  }

  void OnPostInitLogging() override {
    // The launcher supplies the workspace as the process working directory.
    // Without the explicit environment opt-in this performs no timing I/O.
    const auto status = cod3::timing::ConfigureFromEnvironment(std::filesystem::current_path());
    if (status == cod3::timing::StartResult::Recording) {
      REXLOG_INFO("Candidate timing observations: {}", cod3::timing::OutputPath().string());
    }
  }

  void OnPostSetup() override {
    // The window exists and the input system is attached by now.
    cod3::controls::Attach(window());
  }

  void OnShutdown() override {
    cod3::controls::Detach();
    // Any still-active guest call is explicitly recorded as incomplete.
    cod3::timing::Shutdown();
    if (timer_period_set_) {
      cod3::host::DisableHighResolutionTiming();
      timer_period_set_ = false;
    }
  }

 private:
  bool timer_period_set_ = false;

  // Override virtual hooks for customization:
  // void OnPreSetup(rex::RuntimeConfig& config) override {}
  // void OnLoadXexImage(std::string& xex_image) override {}
  // void OnPostLoadXexImage() override {}
  // void OnPostSetup() override {}
  // void OnCreateDialogs(rex::ui::ImGuiDrawer* drawer) override {}
  // std::unique_ptr<rex::ui::ImGuiDialog> CreateAchievementsOverlay() override;
  // std::unique_ptr<rex::ui::AchievementNotificationDialog>
  // CreateAchievementNotificationDialog() override;
  // void OnConfigurePaths(rex::PathConfig& paths) override {}
};
