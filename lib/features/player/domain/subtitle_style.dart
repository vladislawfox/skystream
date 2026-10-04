/// Translating the app's subtitle preferences into libVLC's own scale.
///
/// Two renderers read these. libVLC draws the tracks inside a video, and only
/// takes these settings when the player is created - otherwise it applies its
/// own default of `--freetype-rel-fontsize=16`, which is very large on a
/// full-screen video. SkyStream draws subtitle files itself, from the same
/// numbers, so a file and an embedded track look alike.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../settings/presentation/player_settings_provider.dart';

/// VLC's relative font size is inverted and scale-free: the rendered height is
/// roughly `videoHeight / relativeFontSize`, so a smaller number produces
/// larger text. VLC's own presets run 20 (smaller) to 6 (largest), with 16 as
/// its default.
///
/// [PlayerSettings.subtitleSize] is a Flutter font size in logical pixels,
/// defaulting to 22. This numerator maps the two so the app default lands just
/// below VLC's default while still tracking the slider in the right direction.
/// It is a calibration, not a derivation.
const double _kRelativeSizeNumerator = 528;

/// Builds the engine-side subtitle style from the user's preferences.
VlcSubtitleStyle subtitleStyleFrom(PlayerSettings settings) {
  final size = settings.subtitleSize;
  final relative = size <= 0
      ? 24
      : (_kRelativeSizeNumerator / size).round().clamp(8, 60);

  final background = Color(settings.subtitleBackgroundColor)
      .withValues(alpha: settings.subtitleBackgroundOpacity.clamp(0.0, 1.0));

  return VlcSubtitleStyle(
    relativeFontSize: relative,
    color: Color(settings.subtitleColor),
    // The stored colour's own alpha is discarded above, so opacity 0 is the
    // only way to ask for no box at all — and null, not a transparent colour,
    // is how VLC is told to draw none. The outline is unconditional either
    // way: it keeps white text legible over a bright scene with no box behind
    // it.
    backgroundColor: background.a == 0 ? null : background,
    outlineColor: const Color(0xFF000000),
    outlineThickness: 2,
  );
}

/// Height of the video frame subtitles are scaled against.
///
/// Playback is landscape, so the frame is as tall as the *short* edge of the
/// window no matter which way it is held. On a television the window is
/// already landscape and this is simply its height.
double subtitleFrameHeight(Size window) =>
    math.min(window.width, window.height);

/// The font size [style] is drawn at in a player [area] big: libVLC's rule -
/// the frame height over the relative size - which SkyStream's own subtitles
/// follow too.
double subtitleFontSize(VlcSubtitleStyle style, Size area) =>
    subtitleFrameHeight(area) / (style.relativeFontSize ?? 16);
