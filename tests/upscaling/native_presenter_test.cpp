// Native, headless checks for the isolated ReXGlue spatial presenter overlay.
//
// This test deliberately models only the presenter data types needed by the
// exact GetGuestOutputPaintFlow body extracted by prepare_overlay.py.  It does
// not create a window, a graphics device, a swap chain, or a game/emulator
// process.  The real ReXGlue presenter translation units are compiled by the
// sibling CMake object target; this executable exercises the same flow logic
// and the checked-in shader blobs without requiring a GPU.

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>

namespace spatial_probe {

static unsigned checks = 0;

void Require(bool condition, const char* expression) {
  ++checks;
  if (!condition) {
    throw std::runtime_error(std::string("native presenter check failed: ") + expression);
  }
}

// These are the only presenter CVars consulted by GetGuestOutputPaintFlow.
// The isolated probe keeps the source defaults used by ReXGlue's presenter.
int32_t present_safe_area_x = 90;
int32_t present_safe_area_y = 90;
bool present_letterbox = true;

#define assert_true(expression) ::spatial_probe::Require(bool(expression), #expression)
#define assert_false(expression) ::spatial_probe::Require(!(expression), #expression)
#define assert_not_zero(expression) ::spatial_probe::Require((expression) != 0, #expression)
#define REXCVAR_GET(name) (::spatial_probe::name)
#define REXLOG_WARN(...) ((void)0)

struct GuestOutputProperties {
  uint32_t frontbuffer_width = 0;
  uint32_t frontbuffer_height = 0;
  uint32_t display_aspect_ratio_x = 0;
  uint32_t display_aspect_ratio_y = 0;
  bool is_8bpc = false;

  bool IsActive() const {
    return frontbuffer_width && frontbuffer_height && display_aspect_ratio_x &&
           display_aspect_ratio_y;
  }
};

struct GuestOutputPaintConfig {
  enum class Effect {
    kBilinear,
    kCas,
    kFsr,
    kFsr2,
    kFsr3,
  };

  enum class FsrQualityMode {
    kAuto,
    kNativeAa,
    kQuality,
    kBalanced,
    kPerformance,
    kUltraPerformance,
  };

  static constexpr float kCasAdditionalSharpnessMin = 0.0f;
  static constexpr float kCasAdditionalSharpnessMax = 1.0f;
  static constexpr float kCasAdditionalSharpnessDefault = 0.0f;
  static constexpr uint32_t kFsrMaxUpscalingPassesMax = 4;
  static constexpr float kFsrSharpnessReductionMin = 0.0f;
  static constexpr float kFsrSharpnessReductionMax = 2.0f;
  static constexpr float kFsrSharpnessReductionDefault = 0.2f;

  bool GetAllowOverscanCutoff() const { return allow_overscan_cutoff; }
  Effect GetEffect() const { return effect; }
  float GetCasAdditionalSharpness() const { return cas_additional_sharpness; }
  uint32_t GetFsrMaxUpsamplingPasses() const { return fsr_max_upsampling_passes; }
  float GetFsrSharpnessReduction() const { return fsr_sharpness_reduction; }
  FsrQualityMode GetFsrQualityMode() const { return fsr_quality_mode; }
  bool GetDither() const { return dither; }

  bool allow_overscan_cutoff = false;
  Effect effect = Effect::kBilinear;
  float cas_additional_sharpness = kCasAdditionalSharpnessDefault;
  uint32_t fsr_max_upsampling_passes = kFsrMaxUpscalingPassesMax;
  float fsr_sharpness_reduction = kFsrSharpnessReductionDefault;
  FsrQualityMode fsr_quality_mode = FsrQualityMode::kAuto;
  bool dither = false;
};

enum class GuestOutputPaintEffect {
  kBilinear,
  kBilinearDither,
  kCasSharpen,
  kCasSharpenDither,
  kCasResample,
  kCasResampleDither,
  kFsrEasu,
  kFsrRcas,
  kFsrRcasDither,
  kCount,
};

static constexpr bool CanGuestOutputPaintEffectBeIntermediate(
    GuestOutputPaintEffect effect) {
  switch (effect) {
    case GuestOutputPaintEffect::kBilinear:
    case GuestOutputPaintEffect::kBilinearDither:
    case GuestOutputPaintEffect::kCasSharpenDither:
    case GuestOutputPaintEffect::kCasResampleDither:
    case GuestOutputPaintEffect::kFsrRcasDither:
      return false;
    default:
      return true;
  }
}

static constexpr bool CanGuestOutputPaintEffectBeFinal(GuestOutputPaintEffect effect) {
  return effect != GuestOutputPaintEffect::kFsrEasu;
}

static constexpr std::size_t kMaxGuestOutputPaintEffects =
    GuestOutputPaintConfig::kFsrMaxUpscalingPassesMax + 2;

struct GuestOutputPaintFlow {
  static constexpr std::size_t kMaxClearRectangles = 4;

  struct ClearRectangle {
    uint32_t x = 0;
    uint32_t y = 0;
    uint32_t width = 0;
    uint32_t height = 0;
  };

  GuestOutputProperties properties;
  std::size_t effect_count = 0;
  std::array<GuestOutputPaintEffect, kMaxGuestOutputPaintEffects> effects{};
  std::array<std::pair<uint32_t, uint32_t>, kMaxGuestOutputPaintEffects>
      effect_output_sizes{};
  int32_t output_x = 0;
  int32_t output_y = 0;
  std::size_t letterbox_clear_rectangle_count = 0;
  std::array<ClearRectangle, kMaxClearRectangles> letterbox_clear_rectangles{};
};

// These helpers are only reachable for the temporal FSR2/FSR3 branch.  The
// probe intentionally builds without REX_HAS_FIDELITYFX_RUNTIME, so the
// source-level temporal gate makes them unreachable for every selectable
// effect.  Keep fail-closed stubs here so the exact spatial flow body remains
// compilable and a future accidental temporal selection cannot invent a render
// resolution in this test.
bool QueryTemporalFsrRenderResolutionFromQualityMode(
    uint32_t, uint32_t, GuestOutputPaintConfig::FsrQualityMode, uint32_t&, uint32_t&) {
  return false;
}

void LogTemporalFsrQualityModeInputLimitOnce() {}

// The include is generated from the current ReXGlue source by the isolated
// preparation script.  It contains the exact parser and flow function bodies,
// with only the class method wrapper adapted for a headless call.
#define REX_HAS_FIDELITYFX_SPATIAL 1
#include "../../integration/upscaling/flow_under_test.inc"
#undef REX_HAS_FIDELITYFX_SPATIAL

#undef REXLOG_WARN
#undef REXCVAR_GET
#undef assert_not_zero
#undef assert_false
#undef assert_true

namespace shader_blobs {
using BYTE = unsigned char;
#include "../../tools/rexglue-source/src/ui/shaders/bytecode/d3d12_5_1/guest_output_ffx_cas_resample_ps.h"
#include "../../tools/rexglue-source/src/ui/shaders/bytecode/d3d12_5_1/guest_output_ffx_cas_resample_dither_ps.h"
#include "../../tools/rexglue-source/src/ui/shaders/bytecode/d3d12_5_1/guest_output_ffx_cas_sharpen_ps.h"
#include "../../tools/rexglue-source/src/ui/shaders/bytecode/d3d12_5_1/guest_output_ffx_cas_sharpen_dither_ps.h"
#include "../../tools/rexglue-source/src/ui/shaders/bytecode/d3d12_5_1/guest_output_ffx_fsr_easu_ps.h"
#include "../../tools/rexglue-source/src/ui/shaders/bytecode/d3d12_5_1/guest_output_ffx_fsr_rcas_ps.h"
#include "../../tools/rexglue-source/src/ui/shaders/bytecode/d3d12_5_1/guest_output_ffx_fsr_rcas_dither_ps.h"
}  // namespace shader_blobs

struct ShaderBlob {
  const unsigned char* data;
  std::size_t size;
  const char* name;
  const char* cbuffer_fields[3];
};

uint32_t ReadU32(const unsigned char* data) {
  return uint32_t(data[0]) | (uint32_t(data[1]) << 8) | (uint32_t(data[2]) << 16) |
         (uint32_t(data[3]) << 24);
}

bool ContainsAscii(const ShaderBlob& blob, const char* needle) {
  const std::size_t length = std::strlen(needle);
  if (!length || length > blob.size) {
    return false;
  }
  for (std::size_t offset = 0; offset + length <= blob.size; ++offset) {
    if (std::memcmp(blob.data + offset, needle, length) == 0) {
      return true;
    }
  }
  return false;
}

void CheckDxbcAndConstants(const ShaderBlob& blob) {
  Require(blob.size >= 32, blob.name);
  Require(std::memcmp(blob.data, "DXBC", 4) == 0, blob.name);

  const uint32_t total_size = ReadU32(blob.data + 24);
  const uint32_t chunk_count = ReadU32(blob.data + 28);
  Require(total_size >= 32 && total_size <= blob.size, blob.name);
  Require(chunk_count > 0 && chunk_count <= 64, blob.name);

  bool has_resource_definition = false;
  bool has_shader_program = false;
  for (uint32_t i = 0; i < chunk_count; ++i) {
    const std::size_t offset_table_entry = 32 + std::size_t(i) * 4;
    Require(offset_table_entry + 4 <= blob.size, blob.name);
    const uint32_t chunk_offset = ReadU32(blob.data + offset_table_entry);
    Require(std::size_t(chunk_offset) + 8 <= blob.size, blob.name);
    const uint32_t chunk_size = ReadU32(blob.data + chunk_offset + 4);
    Require(std::size_t(chunk_offset) + 8 + chunk_size <= blob.size, blob.name);
    const unsigned char* tag = blob.data + chunk_offset;
    if (std::memcmp(tag, "RDEF", 4) == 0) {
      has_resource_definition = true;
    }
    if (std::memcmp(tag, "SHDR", 4) == 0 || std::memcmp(tag, "SHEX", 4) == 0) {
      has_shader_program = true;
    }
  }
  Require(has_resource_definition, blob.name);
  Require(has_shader_program, blob.name);
  for (const char* field : blob.cbuffer_fields) {
    Require(ContainsAscii(blob, field), field);
  }
}

GuestOutputPaintConfig MakeConfig(GuestOutputPaintConfig::Effect effect,
                                  uint32_t max_fsr_passes =
                                      GuestOutputPaintConfig::kFsrMaxUpscalingPassesMax) {
  GuestOutputPaintConfig config;
  config.effect = effect;
  config.fsr_max_upsampling_passes = max_fsr_passes;
  return config;
}

void CheckFlowSizes() {
  const GuestOutputProperties source_720p{1280, 720, 16, 9, true};
  const GuestOutputProperties source_360p{640, 360, 16, 9, true};
  const GuestOutputProperties source_above_target{2560, 1440, 16, 9, true};

  const auto fsr_720p = BuildFlow(source_720p, 1920, 1080, 16384, 16384,
                                  MakeConfig(GuestOutputPaintConfig::Effect::kFsr), 1920, 1080);
  Require(fsr_720p.effect_count == 2, "FSR 1280x720 -> 1920x1080 pass count");
  Require(fsr_720p.effects[0] == GuestOutputPaintEffect::kFsrEasu,
          "FSR first pass is EASU");
  Require(fsr_720p.effects[1] == GuestOutputPaintEffect::kFsrRcas,
          "FSR final pass is RCAS");
  Require(fsr_720p.effect_output_sizes[0] == std::make_pair(1920u, 1080u),
          "FSR EASU output size");
  Require(fsr_720p.effect_output_sizes[1] == std::make_pair(1920u, 1080u),
          "FSR RCAS output size");
  Require(fsr_720p.output_x == 0 && fsr_720p.output_y == 0,
          "16:9 output has no letterbox at 1920x1080");

  const auto fsr_360p = BuildFlow(source_360p, 1920, 1080, 16384, 16384,
                                  MakeConfig(GuestOutputPaintConfig::Effect::kFsr), 1920, 1080);
  Require(fsr_360p.effect_count == 3, "FSR 640x360 -> 1920x1080 pass count");
  Require(fsr_360p.effects[0] == GuestOutputPaintEffect::kFsrEasu &&
              fsr_360p.effects[1] == GuestOutputPaintEffect::kFsrEasu &&
              fsr_360p.effects[2] == GuestOutputPaintEffect::kFsrRcas,
          "FSR multi-pass topology");
  Require(fsr_360p.effect_output_sizes[0] == std::make_pair(1280u, 720u) &&
              fsr_360p.effect_output_sizes[1] == std::make_pair(1920u, 1080u),
          "FSR multi-pass intermediate sizes");

  const auto cas_720p = BuildFlow(source_720p, 1920, 1080, 16384, 16384,
                                  MakeConfig(GuestOutputPaintConfig::Effect::kCas), 1920, 1080);
  Require(cas_720p.effect_count == 1, "CAS 1280x720 -> 1920x1080 pass count");
  Require(cas_720p.effects[0] == GuestOutputPaintEffect::kCasResample,
          "CAS upscaling uses resample variant");
  Require(cas_720p.effect_output_sizes[0] == std::make_pair(1920u, 1080u),
          "CAS output size");

  const auto downscale = BuildFlow(
      source_above_target, 1920, 1080, 16384, 16384,
      MakeConfig(GuestOutputPaintConfig::Effect::kFsr), 1920, 1080);
  Require(downscale.effect_count == 1 &&
              downscale.effects[0] == GuestOutputPaintEffect::kCasResample,
          "spatial FSR selection remains bounded for downscale");
}

void CheckShaderBlobs() {
  const ShaderBlob blobs[] = {
      {shader_blobs::guest_output_ffx_cas_resample_ps,
       sizeof(shader_blobs::guest_output_ffx_cas_resample_ps), "CAS resample",
       {"xe_cas_output_offset", "xe_cas_input_output_size_ratio",
        "xe_cas_sharpness_post_setup"}},
      {shader_blobs::guest_output_ffx_cas_resample_dither_ps,
       sizeof(shader_blobs::guest_output_ffx_cas_resample_dither_ps),
       "CAS resample dither",
       {"xe_cas_output_offset", "xe_cas_input_output_size_ratio", "push_consts_xe"}},
      {shader_blobs::guest_output_ffx_cas_sharpen_ps,
       sizeof(shader_blobs::guest_output_ffx_cas_sharpen_ps), "CAS sharpen",
       {"xe_cas_output_offset", "xe_cas_sharpness_post_setup", "push_consts_xe"}},
      {shader_blobs::guest_output_ffx_cas_sharpen_dither_ps,
       sizeof(shader_blobs::guest_output_ffx_cas_sharpen_dither_ps),
       "CAS sharpen dither",
       {"xe_cas_output_offset", "xe_cas_sharpness_post_setup", "push_consts_xe"}},
      {shader_blobs::guest_output_ffx_fsr_easu_ps,
       sizeof(shader_blobs::guest_output_ffx_fsr_easu_ps), "FSR EASU",
       {"xe_fsr_easu_input_output_size_ratio", "xe_fsr_easu_input_size_inv",
        "push_consts_xe"}},
      {shader_blobs::guest_output_ffx_fsr_rcas_ps,
       sizeof(shader_blobs::guest_output_ffx_fsr_rcas_ps), "FSR RCAS",
       {"xe_fsr_rcas_output_offset", "xe_fsr_rcas_sharpness_post_setup",
        "push_consts_xe"}},
      {shader_blobs::guest_output_ffx_fsr_rcas_dither_ps,
       sizeof(shader_blobs::guest_output_ffx_fsr_rcas_dither_ps),
       "FSR RCAS dither",
       {"xe_fsr_rcas_output_offset", "xe_fsr_rcas_sharpness_post_setup", "push_consts_xe"}},
  };
  for (const ShaderBlob& blob : blobs) {
    CheckDxbcAndConstants(blob);
  }
}

void CheckHeadlessAndTemporalGates() {
#ifdef REX_HAS_FIDELITYFX_RUNTIME
#error "The spatial presenter probe must not enable the temporal runtime"
#endif
  Require(ParsePresentEffect("cas") == GuestOutputPaintConfig::Effect::kCas,
          "CAS parser capability");
  Require(ParsePresentEffect("FSR") == GuestOutputPaintConfig::Effect::kFsr,
          "FSR parser capability");
  Require(ParsePresentEffect("fsr2") == GuestOutputPaintConfig::Effect::kBilinear,
          "FSR2 temporal gate");
  Require(ParsePresentEffect("fsr3") == GuestOutputPaintConfig::Effect::kBilinear,
          "FSR3 temporal gate");
}

}  // namespace spatial_probe

int main() {
  try {
    spatial_probe::CheckHeadlessAndTemporalGates();
    spatial_probe::CheckFlowSizes();
    spatial_probe::CheckShaderBlobs();
    std::cout << "{\"checks\":" << spatial_probe::checks
              << ",\"passed\":true,\"host_target\":\"1920x1080\","
                 "\"temporal_runtime\":false,\"guest_clock_modified\":false}"
              << std::endl;
    return 0;
  } catch (const std::exception& exception) {
    std::cerr << exception.what() << std::endl;
    return 1;
  }
}
