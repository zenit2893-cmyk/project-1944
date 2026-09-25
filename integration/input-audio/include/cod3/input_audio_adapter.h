// CoD3 host input/audio boundary policy.
//
// This library deliberately does not enumerate devices, create virtual HID
// devices, call SDL/XInput, or change the guest clock.  It describes the
// command-line policy that a native launcher may pass to ReXGlue and provides
// small, testable conversions that match the existing ReXGlue/Xenia paths.

#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace cod3::input_audio {

enum class InputBackend {
  kSdl3,
  kXInput,
};

enum class InputMode {
  kGamepad,
  kKeyboardMouse,
};

// The values are the Xbox 360/XInput button bit positions consumed by the
// ReXGlue input ABI.  Keeping them here makes the SDL mapping testable without
// including ReXGlue headers in a host-side policy test.
inline constexpr std::uint16_t kGamepadDpadUp = 0x0001;
inline constexpr std::uint16_t kGamepadDpadDown = 0x0002;
inline constexpr std::uint16_t kGamepadDpadLeft = 0x0004;
inline constexpr std::uint16_t kGamepadDpadRight = 0x0008;
inline constexpr std::uint16_t kGamepadStart = 0x0010;
inline constexpr std::uint16_t kGamepadBack = 0x0020;
inline constexpr std::uint16_t kGamepadLeftThumb = 0x0040;
inline constexpr std::uint16_t kGamepadRightThumb = 0x0080;
inline constexpr std::uint16_t kGamepadLeftShoulder = 0x0100;
inline constexpr std::uint16_t kGamepadRightShoulder = 0x0200;
inline constexpr std::uint16_t kGamepadGuide = 0x0400;
inline constexpr std::uint16_t kGamepadA = 0x1000;
inline constexpr std::uint16_t kGamepadB = 0x2000;
inline constexpr std::uint16_t kGamepadX = 0x4000;
inline constexpr std::uint16_t kGamepadY = 0x8000;

struct InputConfig {
  InputBackend backend = InputBackend::kSdl3;
  InputMode mode = InputMode::kGamepad;
  bool mouse_look = false;

  // SDL's built-in mappings remain available when this is empty.  An
  // external GameControllerDB is optional and is never fabricated by this
  // adapter.  A relative path is resolved against the supplied validation
  // base directory only for diagnostics.
  std::optional<std::filesystem::path> mappings_file;
  bool mappings_file_required = false;
};

struct AudioConfig {
  // These are the native ReXGlue/XMA contract used by the supplied title.
  std::uint32_t guest_sample_rate_hz = 48000;
  std::uint8_t guest_channels = 6;

  // AudioSystem clamps this range to [4, 64].  Eight frames is the current
  // default and keeps startup latency bounded without changing guest timing.
  std::uint32_t target_queue_frames = 8;
  std::uint32_t max_queue_frames = 64;
  bool silence_on_underrun = true;
  bool xma_decode = true;
};

enum class ValidationSeverity {
  kWarning,
  kError,
};

struct ValidationIssue {
  ValidationSeverity severity;
  std::string field;
  std::string message;
};

// The base directory is optional.  If it is empty, an external mapping path
// is checked for structural validity but not for existence.  Missing optional
// mappings are warnings, matching the SDL driver's behavior in the captured
// runtime logs; required mappings are errors.
std::vector<ValidationIssue> Validate(
    const InputConfig& input, const AudioConfig& audio,
    const std::filesystem::path& mapping_base_directory = {});

bool HasErrors(const std::vector<ValidationIssue>& issues);

// Build only host input arguments.  It intentionally emits no FPS, clock,
// simulation, or physics switches.  The caller still owns the common game,
// GPU, and user-data arguments.
std::vector<std::string> BuildInputLaunchArguments(const InputConfig& input);

enum class SdlAxis {
  kLeftX,
  kLeftY,
  kRightX,
  kRightY,
};

// Match the existing ReXGlue and Xenia SDL drivers: SDL's vertical axis is
// inverted using the two's-complement XInput convention (~value), while the
// horizontal axes are passed through unchanged.
std::int16_t ConvertSdlAxisToXInput(SdlAxis axis, std::int16_t value);

// Trigger events are expected in the non-negative SDL/XInput range.  Clamp
// malformed host values before the signed shift so a negative event cannot
// become a full trigger through implementation-defined sign extension.
std::uint8_t ConvertSdlTriggerToXInput(std::int16_t value);

// SDL Gamepad button indices in the order used by ReXGlue's driver.  Guide
// and platform-specific extra buttons that map to Guide are omitted when
// guide_button is disabled, exactly as the driver does.
std::optional<std::uint16_t> MapSdlButtonToXInput(std::uint8_t sdl_button,
                                                  bool guide_button);

enum class AudioMixMode {
  kStereoFold,
  kSurroundPassthrough,
};

struct AudioPlan {
  // The ReXGlue SDL driver submits either a two-channel fold or a six-channel
  // stream.  It does not expose arbitrary endpoint channel counts to the
  // callback.
  std::uint8_t stream_channels = 2;
  AudioMixMode mix = AudioMixMode::kStereoFold;
  bool endpoint_was_stereo_or_mono = true;
};

// Select the output-stage contract from the channel count reported by the
// host endpoint.  Mono/stereo endpoints use the explicit 5.1-to-stereo fold;
// all wider endpoints retain the six-channel guest layout.
AudioPlan PlanAudioEndpoint(std::uint16_t endpoint_channels);

}  // namespace cod3::input_audio
