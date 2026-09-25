// Exact source bodies from the isolated presenter overlay; only the method wrapper
// is adapted to provide surface dimensions without constructing a window or GPU.
GuestOutputPaintConfig::Effect ParsePresentEffect(const std::string& effect_name) {
  std::string lowered = effect_name;
  std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                 [](unsigned char c) { return char(std::tolower(c)); });
#if defined(REX_HAS_FIDELITYFX_SPATIAL) && REX_HAS_FIDELITYFX_SPATIAL
  if (lowered == "cas") {
    return GuestOutputPaintConfig::Effect::kCas;
  }
  if (lowered == "fsr") {
    return GuestOutputPaintConfig::Effect::kFsr;
  }
#if defined(REX_HAS_FIDELITYFX_RUNTIME) && REX_HAS_FIDELITYFX_RUNTIME
  if (lowered == "fsr2") {
    return GuestOutputPaintConfig::Effect::kFsr2;
  }
  if (lowered == "fsr3") {
    return GuestOutputPaintConfig::Effect::kFsr3;
  }
#endif
#endif
  return GuestOutputPaintConfig::Effect::kBilinear;
}


GuestOutputPaintFlow BuildFlow(
    const GuestOutputProperties& properties, uint32_t host_rt_width, uint32_t host_rt_height,
    uint32_t max_rt_width, uint32_t max_rt_height, const GuestOutputPaintConfig& config, uint32_t surface_width_in_paint_connection_,
    uint32_t surface_height_in_paint_connection_) {
  GuestOutputPaintFlow flow = {};

  // FIXME(Triang3l): Configuration variables racing with per-game config
  // loading.

  assert_not_zero(max_rt_width);
  assert_not_zero(max_rt_height);

  // Initialize one clear rectangle for the case of drawing no guest output, for
  // consistency with fewer state dependencies.
  flow.letterbox_clear_rectangle_count = 1;
  flow.letterbox_clear_rectangles[0].width = host_rt_width;
  flow.letterbox_clear_rectangles[0].height = host_rt_height;

  // For safety such as division by zero prevention.
  if (!properties.IsActive() || !host_rt_width || !host_rt_height ||
      !surface_width_in_paint_connection_ || !surface_height_in_paint_connection_) {
    return flow;
  }

  flow.properties = properties;

  // Multiplication-division rounding to the nearest.
  auto rescale_unsigned = [](uint32_t value, uint32_t new_scale, uint32_t old_scale) -> uint32_t {
    return uint32_t((uint64_t(value) * new_scale + (old_scale >> 1)) / old_scale);
  };
  auto rescale_signed = [](int32_t value, uint32_t new_scale, uint32_t old_scale) -> int32_t {
    // Plus old_scale / 2 for positive values, minus old_scale / 2 for
    // negative values for consistent rounding for both positive and
    // negative values (as the `/` operator rounds towards zero).
    // Example:
    // (-3 - 1) / 3 == -1
    // (-2 - 1) / 3 == -1
    // (-1 - 1) / 3 == 0
    // ---
    // (0 + 1) / 3 == 0
    // (1 + 1) / 3 == 0
    // (2 + 1) / 3 == 1
    return int32_t((int64_t(value) * new_scale + int32_t(old_scale >> 1) * (value < 0 ? -1 : 1)) /
                   old_scale);
  };

  // Final output location and dimensions.
  // All host location calculations are DPI-independent, conceptually depending
  // only on the aspect ratios, not the absolute values.
  uint32_t output_width, output_height;
  if (uint64_t(surface_width_in_paint_connection_) * properties.display_aspect_ratio_y >
      uint64_t(surface_height_in_paint_connection_) * properties.display_aspect_ratio_x) {
    // The window is wider that the source - crop along Y to preserve the aspect
    // ratio while stretching throughout the entire surface's width, then limit
    // the Y cropping via letterboxing or stretching along X.
    uint32_t present_safe_area;
    if (config.GetAllowOverscanCutoff() && REXCVAR_GET(present_safe_area_y) > 0 &&
        REXCVAR_GET(present_safe_area_y) < 100) {
      present_safe_area = uint32_t(REXCVAR_GET(present_safe_area_y));
    } else {
      present_safe_area = 100;
    }
    // Scale the desired width by the H:W aspect ratio (inverse of W:H) to get
    // the height.
    output_height =
        rescale_unsigned(surface_width_in_paint_connection_, properties.display_aspect_ratio_y,
                         properties.display_aspect_ratio_x);
    bool letterbox = false;
    if (output_height * present_safe_area > surface_height_in_paint_connection_ * 100) {
      // Don't crop out more than the safe area margin - letterbox or stretch.
      output_height = rescale_unsigned(surface_height_in_paint_connection_, 100, present_safe_area);
      letterbox = true;
    }
    if (letterbox && REXCVAR_GET(present_letterbox)) {
      output_width = rescale_unsigned(surface_height_in_paint_connection_ * 100,
                                      properties.display_aspect_ratio_x,
                                      properties.display_aspect_ratio_y * present_safe_area);
      // output_width might have been rounded up already by rescale_unsigned, so
      // rounding down in this division.
      flow.output_x = (int32_t(surface_width_in_paint_connection_) - int32_t(output_width)) / 2;
    } else {
      output_width = surface_width_in_paint_connection_;
      flow.output_x = 0;
    }
    // output_height might have been rounded up already by rescale_unsigned, so
    // rounding down in this division.
    flow.output_y = (int32_t(surface_height_in_paint_connection_) - int32_t(output_height)) / 2;
  } else {
    // The window is taller that the source - crop along X to preserve the
    // aspect ratio while stretching throughout the entire surface's height,
    // then limit the X cropping via letterboxing or stretching along Y.
    uint32_t present_safe_area;
    if (config.GetAllowOverscanCutoff() && REXCVAR_GET(present_safe_area_x) > 0 &&
        REXCVAR_GET(present_safe_area_x) < 100) {
      present_safe_area = uint32_t(REXCVAR_GET(present_safe_area_x));
    } else {
      present_safe_area = 100;
    }
    // Scale the desired height by the W:H aspect ratio to get the width.
    output_width =
        rescale_unsigned(surface_height_in_paint_connection_, properties.display_aspect_ratio_x,
                         properties.display_aspect_ratio_y);
    bool letterbox = false;
    if (output_width * present_safe_area > surface_width_in_paint_connection_ * 100) {
      // Don't crop out more than the safe area margin - letterbox or stretch.
      output_width = rescale_unsigned(surface_width_in_paint_connection_, 100, present_safe_area);
      letterbox = true;
    }
    if (letterbox && REXCVAR_GET(present_letterbox)) {
      output_height = rescale_unsigned(surface_width_in_paint_connection_ * 100,
                                       properties.display_aspect_ratio_y,
                                       properties.display_aspect_ratio_x * present_safe_area);
      // output_height might have been rounded up already by rescale_unsigned,
      // so rounding down in this division.
      flow.output_y = (int32_t(surface_height_in_paint_connection_) - int32_t(output_height)) / 2;
    } else {
      output_height = surface_height_in_paint_connection_;
      flow.output_y = 0;
    }
    // output_width might have been rounded up already by rescale_unsigned, so
    // rounding down in this division.
    flow.output_x = (int32_t(surface_width_in_paint_connection_) - int32_t(output_width)) / 2;
  }

  // Convert the location from surface pixels (which have 1:1 aspect ratio
  // relatively to the physical display) to render target pixels (the render
  // target size may be arbitrary with any aspect ratio, but if it's different
  // than the surface size, the OS is expected to stretch it to the surface
  // boundaries), preserving the aspect ratio.
  if (host_rt_width != surface_width_in_paint_connection_) {
    flow.output_x =
        rescale_signed(flow.output_x, host_rt_width, surface_width_in_paint_connection_);
    output_width =
        rescale_unsigned(output_width, host_rt_width, surface_width_in_paint_connection_);
  }
  if (host_rt_height != surface_height_in_paint_connection_) {
    flow.output_y =
        rescale_signed(flow.output_y, host_rt_height, surface_height_in_paint_connection_);
    output_height =
        rescale_unsigned(output_height, host_rt_height, surface_height_in_paint_connection_);
  }

  // The out-of-bounds checks are needed for correct letterbox calculations.
  // Though this normally shouldn't happen, but in case of rounding issues with
  // extreme values.
  int32_t output_right = flow.output_x + int32_t(output_width);
  int32_t output_bottom = flow.output_y + int32_t(output_height);
  // In rare cases (for example, when surface and render-target coordinate
  // spaces diverge unexpectedly), the computed output may become anchored at
  // the top-left and smaller than the host render target. This results in only
  // a top-left region being presented with black right/bottom areas.
  if (flow.output_x >= 0 && flow.output_y >= 0 && flow.output_x <= 1 && flow.output_y <= 1 &&
      output_width < host_rt_width && output_height < host_rt_height) {
    static std::atomic<bool> logged_top_left_expand = false;
    if (!logged_top_left_expand.exchange(true)) {
      REXLOG_WARN(
          "Presenter: expanding guest output from {}x{} to host render target "
          "{}x{} to avoid top-left-only presentation",
          output_width, output_height, host_rt_width, host_rt_height);
    }
    output_width = host_rt_width;
    output_height = host_rt_height;
    output_right = int32_t(output_width);
    output_bottom = int32_t(output_height);
  }
  if (!output_width || !output_height || output_right <= 0 || output_bottom <= 0 ||
      flow.output_x >= int32_t(host_rt_width) || flow.output_y >= int32_t(host_rt_height)) {
    return flow;
  }

  // The output image may have a part of it outside the final render target (if
  // using the overscan area to stretch the image to the entire surface while
  // preserving the guest aspect ratio if it differs from the host one, for
  // instance). While the final render target size is known to be within the
  // host render target / image size limit, the intermediate images may be
  // larger than that as they include the overscan area that will be outside the
  // screen. Make sure the intermediate images can't be larger than the maximum
  // render target size.
  uint32_t output_width_clamped = std::min(output_width, max_rt_width);
  uint32_t output_height_clamped = std::min(output_height, max_rt_height);

#if defined(REX_HAS_FIDELITYFX_SPATIAL) && REX_HAS_FIDELITYFX_SPATIAL
  if (config.GetEffect() == GuestOutputPaintConfig::Effect::kCas ||
      config.GetEffect() == GuestOutputPaintConfig::Effect::kFsr ||
      config.GetEffect() == GuestOutputPaintConfig::Effect::kFsr2 ||
      config.GetEffect() == GuestOutputPaintConfig::Effect::kFsr3) {
    // FidelityFX Super Resolution and Contrast Adaptive Sharpening only work
    // good for up to 2x2 upscaling due to the way they fetch texels.
    // CAS is primarily a sharpening filter, not an upscaling one (its upscaling
    // eliminates reduces blurriness, but doesn't preserve the shapes of edges,
    // and executing it multiple times will only result in oversharpening. So,
    // using it for scales only of up to 2x2, then simply stretching with
    // bilinear filtering.
    // EASU of FSR, however, preserves edges, it's not supposed to blur them or
    // to make them jagged, so it can be executed multiple times - running
    // multiple EASU passes for scale factors of over 2x2.
    // Just one EASU pass rather than multiple for scaling to factors bigger
    // than 2x2 (especially significantly bigger, such as 1152x640 to 3840x2160,
    // or 3.333x3.375) results in blurry edges and an overall noisy look,
    // multiple passes improve visual stability.
    std::pair<uint32_t, uint32_t> ffx_last_size;
    if (flow.effect_count) {
      ffx_last_size = flow.effect_output_sizes[flow.effect_count - 1];
    } else {
      ffx_last_size.first = properties.frontbuffer_width;
      ffx_last_size.second = properties.frontbuffer_height;
    }
    bool is_temporal_effect = config.GetEffect() == GuestOutputPaintConfig::Effect::kFsr2 ||
                              config.GetEffect() == GuestOutputPaintConfig::Effect::kFsr3;
    bool temporal_quality_mode_forced =
        is_temporal_effect &&
        config.GetFsrQualityMode() != GuestOutputPaintConfig::FsrQualityMode::kAuto;
    if ((config.GetEffect() == GuestOutputPaintConfig::Effect::kFsr || is_temporal_effect) &&
        ((ffx_last_size.first < output_width_clamped ||
          ffx_last_size.second < output_height_clamped) ||
         temporal_quality_mode_forced)) {
      // AMD FidelityFX Super Resolution - upsample along at least one axis.
      // Using the output size clamped to the maximum render target size here as
      // EASU will always write to intermediate images, and RCAS supports only
      // 1:1.
      if (is_temporal_effect) {
        uint32_t temporal_input_width = ffx_last_size.first;
        uint32_t temporal_input_height = ffx_last_size.second;
        uint32_t quality_mode_render_width = 0;
        uint32_t quality_mode_render_height = 0;
        if (QueryTemporalFsrRenderResolutionFromQualityMode(
                output_width_clamped, output_height_clamped, config.GetFsrQualityMode(),
                quality_mode_render_width, quality_mode_render_height)) {
          quality_mode_render_width =
              std::max(uint32_t(1), std::min(quality_mode_render_width, output_width_clamped));
          quality_mode_render_height =
              std::max(uint32_t(1), std::min(quality_mode_render_height, output_height_clamped));
          if (quality_mode_render_width < temporal_input_width ||
              quality_mode_render_height < temporal_input_height) {
            temporal_input_width = quality_mode_render_width;
            temporal_input_height = quality_mode_render_height;
            if (temporal_input_width != ffx_last_size.first ||
                temporal_input_height != ffx_last_size.second) {
              assert_true(flow.effect_count < flow.effects.size());
              flow.effect_output_sizes[flow.effect_count] =
                  std::make_pair(temporal_input_width, temporal_input_height);
              // Pre-temporal quality mode may request a lower render
              // resolution. Use CAS resample since bilinear is not allowed in
              // intermediate passes.
              flow.effects[flow.effect_count++] = GuestOutputPaintEffect::kCasResample;
              ffx_last_size.first = temporal_input_width;
              ffx_last_size.second = temporal_input_height;
            }
          } else if (quality_mode_render_width > temporal_input_width ||
                     quality_mode_render_height > temporal_input_height) {
            LogTemporalFsrQualityModeInputLimitOnce();
          }
        }

        // A single temporal upscaler dispatch can target the final clamped
        // size directly, unlike the spatial multi-pass chain.
        ffx_last_size.first = output_width_clamped;
        ffx_last_size.second = output_height_clamped;
        assert_true(flow.effect_count < flow.effects.size());
        flow.effect_output_sizes[flow.effect_count] = ffx_last_size;
        flow.effects[flow.effect_count++] = GuestOutputPaintEffect::kFsrEasu;
      } else {
        uint32_t easu_max_passes = config.GetFsrMaxUpsamplingPasses();
        uint32_t easu_pass_count = 0;
        while (easu_pass_count < easu_max_passes &&
               (ffx_last_size.first < output_width_clamped ||
                ffx_last_size.second < output_height_clamped)) {
          ffx_last_size.first = std::min(ffx_last_size.first * uint32_t(2), output_width_clamped);
          ffx_last_size.second =
              std::min(ffx_last_size.second * uint32_t(2), output_height_clamped);
          assert_true(flow.effect_count < flow.effects.size());
          flow.effect_output_sizes[flow.effect_count] = ffx_last_size;
          flow.effects[flow.effect_count++] = GuestOutputPaintEffect::kFsrEasu;
          ++easu_pass_count;
        }
      }
      assert_true(flow.effect_count < flow.effects.size());
      flow.effect_output_sizes[flow.effect_count] = ffx_last_size;
      flow.effects[flow.effect_count++] = GuestOutputPaintEffect::kFsrRcas;
    } else {
      // AMD FidelityFX Contrast Adaptive Sharpening - sharpen or downsample, or
      // upsample up to 2x2 if CAS is specified to be used for upscaling too.
      // Using the unclamped output size as CAS may be the last pass - if a
      // bilinear pass is needed afterwards, and the CAS pass will be writing to
      // an intermediate image, the CAS pass output size will be clamped while
      // adding the bilinear stretch.
      std::pair<uint32_t, uint32_t> pre_cas_size = ffx_last_size;
      ffx_last_size.first = std::min(ffx_last_size.first * uint32_t(2), output_width);
      ffx_last_size.second = std::min(ffx_last_size.second * uint32_t(2), output_height);
      assert_true(flow.effect_count < flow.effects.size());
      flow.effect_output_sizes[flow.effect_count] = ffx_last_size;
      flow.effects[flow.effect_count++] = ffx_last_size == pre_cas_size
                                              ? GuestOutputPaintEffect::kCasSharpen
                                              : GuestOutputPaintEffect::kCasResample;
    }
  }
#endif  // defined(REX_HAS_FIDELITYFX_SPATIAL) && REX_HAS_FIDELITYFX_SPATIAL

  std::pair<uint32_t, uint32_t>* last_pre_bilinear_effect_size =
      flow.effect_count ? &flow.effect_output_sizes[flow.effect_count - 1] : nullptr;
  if (!last_pre_bilinear_effect_size || last_pre_bilinear_effect_size->first != output_width ||
      last_pre_bilinear_effect_size->second != output_height) {
    // If not using FidelityFX, or it has reached its upscaling capabilities,
    // but more is needed, stretch via bilinear filtering.
    // Clamp the output size of the last effect to the maximum render target
    // size because it will go to an intermediate image now.
    if (last_pre_bilinear_effect_size) {
#if defined(REX_HAS_FIDELITYFX_SPATIAL) && REX_HAS_FIDELITYFX_SPATIAL
      // RCAS only works for 1:1, clamping must be done explicitly for FSR.
      assert_false(flow.effects[flow.effect_count - 1] == GuestOutputPaintEffect::kFsrRcas &&
                   (last_pre_bilinear_effect_size->first > max_rt_width ||
                    last_pre_bilinear_effect_size->second > max_rt_height));
#endif
      last_pre_bilinear_effect_size->first =
          std::min(last_pre_bilinear_effect_size->first, max_rt_width);
      last_pre_bilinear_effect_size->second =
          std::min(last_pre_bilinear_effect_size->second, max_rt_height);
    }
    assert_true(flow.effect_count < flow.effects.size());
    flow.effect_output_sizes[flow.effect_count] = std::make_pair(output_width, output_height);
    flow.effects[flow.effect_count++] = GuestOutputPaintEffect::kBilinear;
  }

  assert_not_zero(flow.effect_count);

  if (config.GetDither()) {
    // Dithering must be applied only to the final effect since resampling and
    // sharpening filters may considering the dithering noise features and
    // amplify it.
    GuestOutputPaintEffect& last_effect = flow.effects[flow.effect_count - 1];
    switch (last_effect) {
      case GuestOutputPaintEffect::kBilinear:
        // Dithering has no effect for 1:1 copying of a 8bpc image.
        if (!properties.is_8bpc || flow.effect_count > 1 ||
            output_width != properties.frontbuffer_width ||
            output_height != properties.frontbuffer_height) {
          last_effect = GuestOutputPaintEffect::kBilinearDither;
        }
        break;
#if defined(REX_HAS_FIDELITYFX_SPATIAL) && REX_HAS_FIDELITYFX_SPATIAL
      case GuestOutputPaintEffect::kCasSharpen:
        last_effect = GuestOutputPaintEffect::kCasSharpenDither;
        break;
      case GuestOutputPaintEffect::kCasResample:
        last_effect = GuestOutputPaintEffect::kCasResampleDither;
        break;
      case GuestOutputPaintEffect::kFsrRcas:
        last_effect = GuestOutputPaintEffect::kFsrRcasDither;
        break;
#endif
      default:
        break;
    }
  }

#ifndef NDEBUG
  for (size_t i = 0; i + 1 < flow.effect_count; ++i) {
    assert_true(CanGuestOutputPaintEffectBeIntermediate(flow.effects[i]));
  }
  assert_true(CanGuestOutputPaintEffectBeFinal(flow.effects[flow.effect_count - 1]));
#endif

  // Calculate the letterbox geometry.
  if (flow.effect_count) {
    flow.letterbox_clear_rectangle_count = 0;
    uint32_t letterbox_mid_top = uint32_t(std::max(flow.output_y, int32_t(0)));
    // Top.
    if (letterbox_mid_top) {
      assert_true(flow.letterbox_clear_rectangle_count < flow.letterbox_clear_rectangles.size());
      GuestOutputPaintFlow::ClearRectangle& letterbox_clear_rectangle_top =
          flow.letterbox_clear_rectangles[flow.letterbox_clear_rectangle_count++];
      letterbox_clear_rectangle_top.x = 0;
      letterbox_clear_rectangle_top.y = 0;
      letterbox_clear_rectangle_top.width = host_rt_width;
      letterbox_clear_rectangle_top.height = letterbox_mid_top;
    }
    uint32_t letterbox_mid_bottom = std::min(uint32_t(output_bottom), host_rt_height);
    uint32_t letterbox_mid_height = letterbox_mid_bottom - letterbox_mid_top;
    // Middle-left.
    if (flow.output_x > 0) {
      assert_true(flow.letterbox_clear_rectangle_count < flow.letterbox_clear_rectangles.size());
      GuestOutputPaintFlow::ClearRectangle& letterbox_clear_rectangle_left =
          flow.letterbox_clear_rectangles[flow.letterbox_clear_rectangle_count++];
      letterbox_clear_rectangle_left.x = 0;
      letterbox_clear_rectangle_left.y = letterbox_mid_top;
      letterbox_clear_rectangle_left.width = uint32_t(flow.output_x);
      letterbox_clear_rectangle_left.height = letterbox_mid_height;
    }
    // Middle-right.
    if (uint32_t(output_right) < host_rt_width) {
      assert_true(flow.letterbox_clear_rectangle_count < flow.letterbox_clear_rectangles.size());
      GuestOutputPaintFlow::ClearRectangle& letterbox_clear_rectangle_right =
          flow.letterbox_clear_rectangles[flow.letterbox_clear_rectangle_count++];
      letterbox_clear_rectangle_right.x = uint32_t(output_right);
      letterbox_clear_rectangle_right.y = letterbox_mid_top;
      letterbox_clear_rectangle_right.width = host_rt_width - uint32_t(output_right);
      letterbox_clear_rectangle_right.height = letterbox_mid_height;
    }
    // Bottom.
    if (letterbox_mid_bottom < host_rt_height) {
      assert_true(flow.letterbox_clear_rectangle_count < flow.letterbox_clear_rectangles.size());
      GuestOutputPaintFlow::ClearRectangle& letterbox_clear_rectangle_top =
          flow.letterbox_clear_rectangles[flow.letterbox_clear_rectangle_count++];
      letterbox_clear_rectangle_top.x = 0;
      letterbox_clear_rectangle_top.y = letterbox_mid_bottom;
      letterbox_clear_rectangle_top.width = host_rt_width;
      letterbox_clear_rectangle_top.height = host_rt_height - letterbox_mid_bottom;
    }
  }

  return flow;
}
