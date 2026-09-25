#include "cod3/input_audio_adapter.h"

#include <algorithm>
#include <array>
#include <system_error>
#include <utility>

namespace cod3::input_audio {

namespace {

constexpr std::uint32_t kGuestSampleRateHz = 48000;
constexpr std::uint8_t kGuestChannels = 6;
constexpr std::uint32_t kMinimumQueueFrames = 4;
constexpr std::uint32_t kMaximumQueueFrames = 64;

void AddIssue(std::vector<ValidationIssue>& issues, ValidationSeverity severity,
              std::string field, std::string message) {
  issues.push_back(
      ValidationIssue{severity, std::move(field), std::move(message)});
}

std::string BackendName(InputBackend backend) {
  switch (backend) {
    case InputBackend::kSdl3:
      return "sdl";
    case InputBackend::kXInput:
      return "xinput";
  }
  return {};
}

bool IsKnownInputMode(InputMode mode) {
  switch (mode) {
    case InputMode::kGamepad:
    case InputMode::kKeyboardMouse:
      return true;
  }
  return false;
}

void AddArgument(std::vector<std::string>& args, std::string_view name,
                 std::string_view value) {
  std::string argument;
  argument.reserve(name.size() + value.size() + 3);
  argument.append("--");
  argument.append(name);
  argument.push_back('=');
  argument.append(value);
  args.push_back(std::move(argument));
}

void AddKeyboardMouseBindings(std::vector<std::string>& args) {
  // Keep this list aligned with the current launcher preset.  D-pad arrows
  // deliberately carry Shift: the ReXGlue defaults use this chord to avoid
  // driving the right-stick keybinds (bare arrows) at the same time.
  constexpr std::array<std::pair<std::string_view, std::string_view>, 19>
      bindings = {{
          {"keybind_a", "Space"},
          {"keybind_b", "C,Backspace"},
          {"keybind_x", "R,F"},
          {"keybind_y", "Q"},
          {"keybind_left_trigger", "RMB"},
          {"keybind_right_trigger", "LMB"},
          {"keybind_left_shoulder", "4"},
          {"keybind_right_shoulder", "G"},
          {"keybind_lstick_up", "W,Shift+W"},
          {"keybind_lstick_down", "S,Shift+S"},
          {"keybind_lstick_left", "A,Shift+A"},
          {"keybind_lstick_right", "D,Shift+D"},
          {"keybind_lstick_press", "Shift+W"},
          {"keybind_rstick_press", "V,MMB"},
          {"keybind_dpad_up", "Shift+Up"},
          {"keybind_dpad_down", "Shift+Down"},
          {"keybind_dpad_left", "Shift+Left"},
          {"keybind_dpad_right", "Shift+Right"},
          {"keybind_start", "Return,Escape"},
      }};
  for (const auto& [name, value] : bindings) {
    AddArgument(args, name, value);
  }
  AddArgument(args, "keybind_back", "Tab");
}

constexpr std::array<std::uint16_t, 21> kSdlButtonToXInput = {{
    kGamepadA,
    kGamepadB,
    kGamepadX,
    kGamepadY,
    kGamepadBack,
    kGamepadGuide,
    kGamepadStart,
    kGamepadLeftThumb,
    kGamepadRightThumb,
    kGamepadLeftShoulder,
    kGamepadRightShoulder,
    kGamepadDpadUp,
    kGamepadDpadDown,
    kGamepadDpadLeft,
    kGamepadDpadRight,
    kGamepadGuide,
    kGamepadY,
    kGamepadB,
    kGamepadX,
    kGamepadA,
    kGamepadGuide,
}};

}  // namespace

std::vector<ValidationIssue> Validate(
    const InputConfig& input, const AudioConfig& audio,
    const std::filesystem::path& mapping_base_directory) {
  std::vector<ValidationIssue> issues;

  // The enum types make invalid values difficult to construct, but keeping a
  // default branch makes future additions fail closed instead of silently
  // selecting a backend.
  if (BackendName(input.backend).empty()) {
    AddIssue(issues, ValidationSeverity::kError, "input.backend",
             "unknown input backend");
  }

  if (!IsKnownInputMode(input.mode)) {
    AddIssue(issues, ValidationSeverity::kError, "input.mode",
             "unknown input mode");
  }

  if (input.mode == InputMode::kGamepad && input.mouse_look) {
    AddIssue(issues, ValidationSeverity::kError, "input.mouse_look",
             "mouse look requires keyboard/mouse mode");
  }

  if (input.mappings_file && input.mappings_file->empty()) {
    AddIssue(issues, ValidationSeverity::kError, "input.mappings_file",
             "mapping path must be non-empty when supplied");
  }

  if (input.backend == InputBackend::kXInput && input.mappings_file) {
    AddIssue(issues, ValidationSeverity::kWarning, "input.mappings_file",
             "SDL mapping files are ignored by the XInput backend");
  }

  if (input.mappings_file && !input.mappings_file->empty()) {
    const auto& configured_path = *input.mappings_file;

    if (!mapping_base_directory.empty()) {
      std::filesystem::path path = configured_path;
      if (path.is_relative()) {
        path = mapping_base_directory / path;
      }
      std::error_code ec;
      const bool exists = std::filesystem::exists(path, ec);
      if (ec) {
        AddIssue(issues, ValidationSeverity::kWarning, "input.mappings_file",
                 "could not inspect mapping path: " + ec.message());
      } else if (!exists) {
        AddIssue(issues, input.mappings_file_required
                           ? ValidationSeverity::kError
                           : ValidationSeverity::kWarning,
                 "input.mappings_file",
                 input.mappings_file_required
                     ? "required mapping file does not exist"
                     : "optional mapping file does not exist; SDL built-in mappings remain available");
      } else if (!std::filesystem::is_regular_file(path, ec) || ec) {
        AddIssue(issues, ValidationSeverity::kError, "input.mappings_file",
                 "mapping path is not a regular file");
      }
    }
  } else if (input.mappings_file_required) {
    AddIssue(issues, ValidationSeverity::kError, "input.mappings_file",
             "a required mapping file was not configured");
  }

  if (audio.guest_sample_rate_hz != kGuestSampleRateHz) {
    AddIssue(issues, ValidationSeverity::kError, "audio.guest_sample_rate_hz",
             "the XMA/SDL path requires 48000 Hz");
  }
  if (audio.guest_channels != kGuestChannels) {
    AddIssue(issues, ValidationSeverity::kError, "audio.guest_channels",
             "the ReXGlue SDL callback consumes six guest channels");
  }
  if (audio.target_queue_frames < kMinimumQueueFrames ||
      audio.target_queue_frames > kMaximumQueueFrames) {
    AddIssue(issues, ValidationSeverity::kError, "audio.target_queue_frames",
             "target queue must be between 4 and 64 frames");
  }
  if (audio.max_queue_frames < kMinimumQueueFrames ||
      audio.max_queue_frames > kMaximumQueueFrames) {
    AddIssue(issues, ValidationSeverity::kError, "audio.max_queue_frames",
             "maximum queue must be between 4 and 64 frames");
  }
  if (audio.target_queue_frames > audio.max_queue_frames) {
    AddIssue(issues, ValidationSeverity::kError, "audio.target_queue_frames",
             "target queue cannot exceed the maximum queue");
  }
  if (!audio.silence_on_underrun) {
    AddIssue(issues, ValidationSeverity::kError, "audio.silence_on_underrun",
             "underruns must produce silence instead of stale guest samples");
  }
  if (!audio.xma_decode) {
    AddIssue(issues, ValidationSeverity::kError, "audio.xma_decode",
             "XMA decoding is required for the title audio path");
  }

  return issues;
}

bool HasErrors(const std::vector<ValidationIssue>& issues) {
  return std::any_of(issues.begin(), issues.end(), [](const ValidationIssue& issue) {
    return issue.severity == ValidationSeverity::kError;
  });
}

std::vector<std::string> BuildInputLaunchArguments(const InputConfig& input) {
  std::vector<std::string> args;
  AddArgument(args, "input_backend", BackendName(input.backend));

  if (input.mode == InputMode::kKeyboardMouse) {
    AddArgument(args, "mnk_mode", "true");
    AddArgument(args, "mnk_mouse", input.mouse_look ? "true" : "false");
    AddKeyboardMouseBindings(args);
  } else {
    AddArgument(args, "mnk_mode", "false");
    AddArgument(args, "mnk_mouse", "false");
  }

  if (input.mappings_file && !input.mappings_file->empty()) {
    AddArgument(args, "hid_mappings_file", input.mappings_file->string());
  } else if (input.backend == InputBackend::kSdl3) {
    // The SDK's default is "gamecontrollerdb.txt".  Explicitly disabling an
    // absent optional file keeps the launch log clean while retaining SDL's
    // built-in controller mappings.  This does not add or emulate a device.
    AddArgument(args, "hid_mappings_file", "");
  }
  return args;
}

std::int16_t ConvertSdlAxisToXInput(SdlAxis axis, std::int16_t value) {
  switch (axis) {
    case SdlAxis::kLeftY:
    case SdlAxis::kRightY:
      // Written arithmetically instead of using unary ~ so the intended
      // two's-complement mapping is clear and no integral-promotion warning
      // is involved.  This is exactly static_cast<int16_t>(~value).
      return static_cast<std::int16_t>(-static_cast<std::int32_t>(value) - 1);
    case SdlAxis::kLeftX:
    case SdlAxis::kRightX:
      return value;
  }
  return 0;
}

std::uint8_t ConvertSdlTriggerToXInput(std::int16_t value) {
  const auto non_negative = std::clamp<std::int32_t>(
      static_cast<std::int32_t>(value), 0, INT16_MAX);
  return static_cast<std::uint8_t>(non_negative >> 7);
}

std::optional<std::uint16_t> MapSdlButtonToXInput(std::uint8_t sdl_button,
                                                  bool guide_button) {
  if (sdl_button >= kSdlButtonToXInput.size()) {
    return std::nullopt;
  }
  const auto mapped = kSdlButtonToXInput[sdl_button];
  if (mapped == kGamepadGuide && !guide_button) {
    return std::nullopt;
  }
  return mapped;
}

AudioPlan PlanAudioEndpoint(std::uint16_t endpoint_channels) {
  if (endpoint_channels <= 2) {
    return AudioPlan{2, AudioMixMode::kStereoFold, true};
  }
  return AudioPlan{6, AudioMixMode::kSurroundPassthrough, false};
}

}  // namespace cod3::input_audio
