#include "cod3/input_audio_adapter.h"

#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <string>
#include <string_view>
#include <vector>

namespace {

int failures = 0;

void Check(bool condition, std::string_view message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

bool HasArgument(const std::vector<std::string>& args, std::string_view expected) {
  return std::find(args.begin(), args.end(), expected) != args.end();
}

bool HasPrefix(const std::vector<std::string>& args, std::string_view prefix) {
  return std::any_of(args.begin(), args.end(), [&](const std::string& value) {
    return value.starts_with(prefix);
  });
}

bool HasIssueField(const std::vector<cod3::input_audio::ValidationIssue>& issues,
                   std::string_view field) {
  return std::any_of(issues.begin(), issues.end(), [&](const auto& issue) {
    return issue.field == field;
  });
}

}  // namespace

int main(int argc, char** argv) {
  using namespace cod3::input_audio;

  const std::filesystem::path integration_root =
      argc > 1 ? std::filesystem::path(argv[1]) : std::filesystem::path{};

  InputConfig keyboard_mouse;
  keyboard_mouse.mode = InputMode::kKeyboardMouse;
  keyboard_mouse.mouse_look = true;
  keyboard_mouse.mappings_file = "include/cod3/input_audio_adapter.h";

  AudioConfig audio;
  const auto valid_issues = Validate(keyboard_mouse, audio, integration_root);
  Check(!HasErrors(valid_issues), "valid keyboard/mouse profile validates");
  Check(!HasIssueField(valid_issues, "audio.guest_sample_rate_hz"),
        "valid audio profile keeps the 48 kHz contract");

  const auto keyboard_args = BuildInputLaunchArguments(keyboard_mouse);
  Check(HasArgument(keyboard_args, "--input_backend=sdl"),
        "SDL3 backend is explicit");
  Check(HasArgument(keyboard_args, "--mnk_mode=true"),
        "keyboard/mouse mode is explicit");
  Check(HasArgument(keyboard_args, "--mnk_mouse=true"),
        "mouse look is explicit");
  Check(HasArgument(keyboard_args, "--keybind_left_trigger=RMB"),
        "right mouse is the left trigger/aim input");
  Check(HasArgument(keyboard_args, "--keybind_right_trigger=LMB"),
        "left mouse is the right trigger/fire input");
  Check(HasArgument(keyboard_args, "--keybind_dpad_up=Shift+Up"),
        "D-pad up uses the modifier chord");
  Check(HasArgument(keyboard_args, "--keybind_dpad_down=Shift+Down"),
        "D-pad down uses the modifier chord");
  Check(HasArgument(keyboard_args, "--keybind_dpad_left=Shift+Left"),
        "D-pad left uses the modifier chord");
  Check(HasArgument(keyboard_args, "--keybind_dpad_right=Shift+Right"),
        "D-pad right uses the modifier chord");
  Check(!HasArgument(keyboard_args, "--keybind_dpad_up=Up"),
        "D-pad does not duplicate the right-stick up keybind");
  Check(HasArgument(keyboard_args,
                    "--hid_mappings_file=include/cod3/input_audio_adapter.h"),
        "configured mapping path is forwarded");

  const auto has_timing_switch = [](const std::string& argument) {
    return argument.starts_with("--fps") ||
           argument.starts_with("--clock") ||
           argument.starts_with("--tick") ||
           argument.starts_with("--physics") ||
           argument.starts_with("--simulation");
  };
  Check(std::none_of(keyboard_args.begin(), keyboard_args.end(), has_timing_switch),
        "input adapter does not modify guest timing or physics");

  InputConfig gamepad;
  const auto gamepad_args = BuildInputLaunchArguments(gamepad);
  Check(HasArgument(gamepad_args, "--mnk_mode=false"),
        "gamepad mode disables keyboard/mouse emulation");
  Check(HasArgument(gamepad_args, "--mnk_mouse=false"),
        "gamepad mode disables mouse look");
  Check(!HasPrefix(gamepad_args, "--keybind_"),
        "gamepad mode does not overwrite keyboard bindings");
  Check(HasArgument(gamepad_args, "--hid_mappings_file="),
        "SDL profile explicitly disables absent optional DB");

  InputConfig xinput;
  xinput.backend = InputBackend::kXInput;
  const auto xinput_args = BuildInputLaunchArguments(xinput);
  Check(HasArgument(xinput_args, "--input_backend=xinput"),
        "XInput backend can be selected explicitly");
  Check(!HasPrefix(xinput_args, "--hid_mappings_file"),
        "XInput profile does not pass an SDL mapping file");

  Check(MapSdlButtonToXInput(0, false) == kGamepadA,
        "SDL south button maps to XInput A");
  Check(MapSdlButtonToXInput(1, false) == kGamepadB,
        "SDL east button maps to XInput B");
  Check(MapSdlButtonToXInput(2, false) == kGamepadX,
        "SDL west button maps to XInput X");
  Check(MapSdlButtonToXInput(3, false) == kGamepadY,
        "SDL north button maps to XInput Y");
  Check(!MapSdlButtonToXInput(5, false),
        "Guide is suppressed by default");
  Check(MapSdlButtonToXInput(5, true) == kGamepadGuide,
        "Guide can be explicitly enabled");
  Check(!MapSdlButtonToXInput(21, true),
        "unknown SDL button is ignored");

  Check(ConvertSdlAxisToXInput(SdlAxis::kLeftX, 1234) == 1234,
        "horizontal SDL axis is preserved");
  Check(ConvertSdlAxisToXInput(SdlAxis::kLeftY, 0) == -1,
        "vertical zero follows the ReXGlue/Xenia complement contract");
  Check(ConvertSdlAxisToXInput(SdlAxis::kLeftY, INT16_MAX) == INT16_MIN,
        "positive vertical endpoint maps to negative XInput endpoint");
  Check(ConvertSdlAxisToXInput(SdlAxis::kRightY, INT16_MIN) == INT16_MAX,
        "negative vertical endpoint maps to positive XInput endpoint");
  Check(ConvertSdlTriggerToXInput(-1) == 0,
        "malformed negative trigger is clamped to neutral");
  Check(ConvertSdlTriggerToXInput(127) == 0,
        "trigger conversion preserves the 128-count quantization boundary");
  Check(ConvertSdlTriggerToXInput(128) == 1,
        "trigger conversion shifts valid values to the XInput byte range");
  Check(ConvertSdlTriggerToXInput(INT16_MAX) == 255,
        "maximum trigger maps to 255");

  const auto mono = PlanAudioEndpoint(1);
  Check(mono.stream_channels == 2 && mono.mix == AudioMixMode::kStereoFold,
        "mono endpoint uses explicit stereo fold output");
  const auto stereo = PlanAudioEndpoint(2);
  Check(stereo.stream_channels == 2 && stereo.mix == AudioMixMode::kStereoFold,
        "stereo endpoint uses explicit stereo fold output");
  const auto surround = PlanAudioEndpoint(6);
  Check(surround.stream_channels == 6 &&
            surround.mix == AudioMixMode::kSurroundPassthrough,
        "wider endpoint keeps the six-channel guest layout");
  const auto other_wide = PlanAudioEndpoint(8);
  Check(other_wide.stream_channels == 6 &&
            other_wide.mix == AudioMixMode::kSurroundPassthrough,
        "other wide endpoints use the supported six-channel stream");

  InputConfig missing_mapping;
  missing_mapping.mappings_file = "missing-gamecontrollerdb.txt";
  const auto optional_missing =
      Validate(missing_mapping, audio, integration_root);
  Check(!HasErrors(optional_missing),
        "missing optional mapping is a warning, not a startup failure");
  missing_mapping.mappings_file_required = true;
  const auto required_missing =
      Validate(missing_mapping, audio, integration_root);
  Check(HasErrors(required_missing),
        "missing required mapping fails closed");

  InputConfig conflicting_input;
  conflicting_input.mouse_look = true;
  const auto conflicting_issues = Validate(conflicting_input, audio);
  Check(HasErrors(conflicting_issues),
        "mouse look cannot be enabled for a physical-gamepad profile");

  AudioConfig invalid_audio = audio;
  invalid_audio.guest_sample_rate_hz = 44100;
  invalid_audio.guest_channels = 2;
  invalid_audio.target_queue_frames = 3;
  invalid_audio.max_queue_frames = 2;
  invalid_audio.silence_on_underrun = false;
  invalid_audio.xma_decode = false;
  const auto invalid_issues = Validate(gamepad, invalid_audio);
  Check(HasErrors(invalid_issues), "invalid audio profile fails closed");
  Check(HasIssueField(invalid_issues, "audio.guest_sample_rate_hz"),
        "invalid sample rate is reported");
  Check(HasIssueField(invalid_issues, "audio.guest_channels"),
        "invalid channel count is reported");
  Check(HasIssueField(invalid_issues, "audio.target_queue_frames"),
        "invalid queue target is reported");
  Check(HasIssueField(invalid_issues, "audio.silence_on_underrun"),
        "unsafe underrun behavior is reported");
  Check(HasIssueField(invalid_issues, "audio.xma_decode"),
        "disabled XMA decode is reported");

  if (failures == 0) {
    std::cout << "PASS: input/audio policy contract (" << keyboard_args.size()
              << " keyboard args, " << gamepad_args.size() << " gamepad args)\n";
    return 0;
  }
  std::cerr << "FAILURES: " << failures << '\n';
  return 1;
}
