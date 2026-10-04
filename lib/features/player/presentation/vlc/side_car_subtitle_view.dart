/// The side-car subtitle on screen: drawn by SkyStream over the video, not by
/// libVLC into it.
///
/// Laid out against the player area rather than the picture, so Zoom and
/// Stretch never move, scale or cut off a line - the fit changes the picture
/// under the text and nothing else. Sized and styled from the same numbers
/// the settings preview and libVLC use ([subtitleFontSize]), so a subtitle
/// file reads like a track inside the video, and follows a settings change at
/// once.
///
/// Timed off the engine's clock with its subtitle delay applied. The engine
/// reports its position a few times a second, so between reports the clock is
/// run on here at the playback speed, and one timer wakes the view at the next
/// line's start or end: a line lands on its frame rather than up to half a
/// second after it, and nothing is rebuilt in between.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show Bidi;
import 'package:vlc_player/vlc_player.dart';

import '../../../settings/presentation/player_settings_provider.dart';
import '../../domain/side_car_subtitles.dart';
import '../../domain/subtitle_cues.dart';
import '../../domain/subtitle_style.dart';

/// How far the clock is run on past the engine's last report. Past this the
/// engine is late rather than between reports - a stall it has not announced
/// yet - and subtitles running on over a frozen picture are worse than ones
/// that wait.
const Duration _kMaxRunOn = Duration(seconds: 1);

/// Space between the lines and the edge of the player area, as a share of the
/// frame height.
const double _kEdgeMargin = 0.06;

/// Space the text keeps from each side, as a share of the width.
const double _kSideMargin = 0.05;

/// The side-car subtitle on screen. Draws nothing while no side-car is on or
/// no line is due.
class SideCarSubtitleView extends StatefulWidget {
  const SideCarSubtitleView({
    required this.controller,
    required this.subtitles,
    required this.settings,
    this.bottomInset = 0,
    this.clock,
    super.key,
  });

  final VlcPlayerController controller;
  final SideCarSubtitles subtitles;
  final PlayerSettings settings;

  /// Room to leave along the bottom - the controls, while they are up - so a
  /// line is lifted over them rather than drawn under them. A change slides
  /// the lines rather than jumping them.
  final double bottomInset;

  /// Time since a fixed moment, which the clock between the engine's reports
  /// is run on from. A stopwatch unless given; a test gives the fake clock
  /// its timers run on.
  final Duration Function()? clock;

  @override
  State<SideCarSubtitleView> createState() => _SideCarSubtitleViewState();
}

class _SideCarSubtitleViewState extends State<SideCarSubtitleView> {
  final Stopwatch _stopwatch = Stopwatch()..start();

  Duration get _now => widget.clock?.call() ?? _stopwatch.elapsed;

  /// Wakes the view when the lines on screen next change.
  Timer? _wake;

  /// The engine's last reported position, and when on [_now] it came.
  Duration _reported = Duration.zero;
  Duration _reportedAt = Duration.zero;

  List<SubtitleCue> _shown = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onEngine);
    widget.subtitles.addListener(_refresh);
    _onEngine();
  }

  @override
  void didUpdateWidget(SideCarSubtitleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onEngine);
      widget.controller.addListener(_onEngine);
    }
    if (oldWidget.subtitles != widget.subtitles) {
      oldWidget.subtitles.removeListener(_refresh);
      widget.subtitles.addListener(_refresh);
    }
    _onEngine();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onEngine);
    widget.subtitles.removeListener(_refresh);
    _wake?.cancel();
    super.dispose();
  }

  void _onEngine() {
    final value = widget.controller.value;
    if (value.position != _reported) {
      _reported = value.position;
      _reportedAt = _now;
    }
    _refresh();
  }

  /// How far the clock has been run on past the engine's last report.
  Duration get _runOn {
    final since = _now - _reportedAt;
    return since > _kMaxRunOn ? _kMaxRunOn : since;
  }

  void _refresh() {
    _wake?.cancel();
    _wake = null;
    if (!mounted) return;
    final value = widget.controller.value;
    final timeline = widget.subtitles.timeline;
    final playing = value.isPlaying && value.playbackSpeed > 0;
    final runOn = playing ? _runOn : Duration.zero;
    // The position the file's times are read against: where playback is,
    // less the delay - a positive delay shows every line later.
    final at =
        _reported +
        runOn * (playing ? value.playbackSpeed : 1) -
        value.subtitleDelay;
    final due = timeline.isEmpty ? const <SubtitleCue>[] : timeline.at(at);
    if (!listEquals(due, _shown)) setState(() => _shown = due);

    // Past the run-on limit the next report is what moves anything.
    if (!playing || runOn >= _kMaxRunOn) return;
    final next = timeline.nextChange(at);
    if (next == null) return;
    final wait = (next - at) * (1 / value.playbackSpeed);
    // A millisecond over, so the wake lands inside the new line, not on the
    // edge of the old one.
    _wake = Timer(wait + const Duration(milliseconds: 1), _refresh);
  }

  @override
  Widget build(BuildContext context) {
    if (_shown.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) => _lines(constraints.biggest),
        ),
      ),
    );
  }

  Widget _lines(Size area) {
    final style = subtitleStyleFrom(widget.settings);
    final fontSize = subtitleFontSize(style, area);
    final margin = subtitleFrameHeight(area) * _kEdgeMargin;
    final side = area.width * _kSideMargin;

    List<Widget> band(SubtitlePlacement placement) => [
      for (final cue in _shown)
        if (cue.placement == placement) _cue(cue, style, fontSize),
    ];

    // Where two lines are due together the earlier one keeps its place and
    // the later one stacks away from the edge, as libass lays them out.
    final bottom = band(SubtitlePlacement.bottom).reversed.toList();
    final middle = band(SubtitlePlacement.middle);
    final top = band(SubtitlePlacement.top);

    return Stack(
      children: [
        if (top.isNotEmpty)
          Positioned(top: margin, left: side, right: side, child: _column(top)),
        if (middle.isNotEmpty)
          Positioned.fill(
            left: side,
            right: side,
            child: Center(child: _column(middle)),
          ),
        if (bottom.isNotEmpty)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            bottom: math.max(margin, widget.bottomInset + margin / 2),
            left: side,
            right: side,
            child: _column(bottom),
          ),
      ],
    );
  }

  Widget _column(List<Widget> cues) =>
      Column(mainAxisSize: MainAxisSize.min, children: cues);

  /// One cue: the text over its outline, in a box when the viewer asked for
  /// one - the preview's drawing, at the player's size.
  Widget _cue(SubtitleCue cue, VlcSubtitleStyle style, double fontSize) {
    final outline = (style.outlineThickness ?? 0).toDouble();
    final direction = Bidi.detectRtlDirectionality(cue.text)
        ? TextDirection.rtl
        : TextDirection.ltr;
    final base = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      height: 1.2,
    );

    Widget text(TextStyle paint) => Text.rich(
      TextSpan(
        style: base.merge(paint),
        children: [
          for (final span in cue.spans)
            TextSpan(
              text: span.text,
              style: TextStyle(
                fontStyle: span.italic ? FontStyle.italic : null,
                fontWeight: span.bold ? FontWeight.w800 : null,
              ),
            ),
        ],
      ),
      textAlign: TextAlign.center,
      textDirection: direction,
    );

    return Padding(
      padding: EdgeInsets.only(top: fontSize * 0.15),
      child: DecoratedBox(
        decoration: BoxDecoration(color: style.backgroundColor),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: fontSize * 0.3,
            vertical: fontSize * 0.05,
          ),
          child: Stack(
            children: [
              // A Text cannot outline its glyphs, so the outline is a stroked
              // copy underneath, as in the settings preview.
              if (outline > 0)
                text(
                  TextStyle(
                    foreground: Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = outline
                      ..strokeJoin = StrokeJoin.round
                      ..color = style.outlineColor ?? const Color(0xFF000000),
                  ),
                ),
              text(TextStyle(color: style.color)),
            ],
          ),
        ),
      ),
    );
  }
}
