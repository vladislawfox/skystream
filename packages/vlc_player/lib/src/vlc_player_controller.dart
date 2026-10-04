import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState, WidgetsBinding;

import 'vlc_media_info.dart';
import 'vlc_http_headers.dart';
import 'vlc_media_source.dart';
import 'vlc_player_config.dart';
import 'vlc_media_stats.dart';
import 'vlc_player_controller_internals.dart';
import 'vlc_player_error.dart';
import 'vlc_player_value.dart';
import 'vlc_video_fit.dart';
import 'vlc_video_geometry.dart';

/// Playlist repeat behavior used by `VlcPlayerController.setPlaylist`.
enum VlcPlaylistLoopMode {
  /// Stop at the beginning or end of the playlist.
  none,

  /// Repeat the current playlist item when it ends.
  loopOne,

  /// Wrap to the first or last item when advancing past an edge.
  loopAll,
}

/// Controls a `VlcPlayer` and exposes playback state.
///
/// A controller can be configured before it is attached to a widget. Calls to
/// [setMedia] or [setPlaylist] are remembered and applied when the native
/// player is created. Playback commands such as [play] and [pause] require the
/// controller to be attached to a `VlcPlayer`.
abstract class VlcPlayerController extends ValueNotifier<VlcPlayerValue> {
  /// Creates a controller.
  ///
  /// Use [mediaSource] when an initial media item should be applied when the
  /// native player is created.
  /// Prefer [config] over hand-written [options]: it is typed, documented, and
  /// spells the VLC flags for you. When both are given, [config] is expanded
  /// first and [options] appended, so a raw option always wins over the
  /// generated equivalent.
  factory VlcPlayerController({
    VlcMediaSource? mediaSource,
    bool autoPlay = false,
    VlcPlayerConfig? config,
    List<String> options = const <String>[],
    Duration? eventThrottleInterval,
    Duration stallIndicatorDelay = const Duration(milliseconds: 1000),
  }) {
    return _VlcPlayerController(
      mediaSource: mediaSource,
      autoPlay: autoPlay,
      options: <String>[...?config?.toOptions(), ...options],
      eventThrottleInterval: eventThrottleInterval,
      stallIndicatorDelay: stallIndicatorDelay,
      // The nullable value, not the resolved one: the platform default is
      // read at the moment it is needed so a const config cannot freeze it.
      configuredBackgroundPolicy: config?.backgroundPolicy,
    );
  }

  VlcPlayerController._() : super(const VlcPlayerValue());

  /// Whether the initially configured media source should start playback
  /// immediately.
  bool get autoPlay;

  /// VLC instance options applied when the native player is created.
  List<String> get options;

  /// Optional interval used to coalesce progress-only native events.
  ///
  /// When set to a positive duration, updates that only change playback
  /// position, media duration, or buffering progress are delivered at most once
  /// per interval. State, readiness, track metadata, volume, speed, and errors
  /// still notify listeners immediately. The default `null` keeps every
  /// distinct native value update visible immediately.
  Duration? get eventThrottleInterval;

  /// How long the position clock may stand still on a playing player before
  /// [VlcPlayerValue.isStalled] is raised.
  ///
  /// The default of one second is not a taste choice. The desktop backends
  /// poll libVLC every 500 ms and the host may throttle events on top of that
  /// ([eventThrottleInterval]), so two consecutive snapshots of healthy
  /// playback can legitimately be up to poll-plus-throttle apart. A delay
  /// shorter than that reads the gap between polls as a stall and flickers a
  /// spinner over a video that is playing fine. Anything set here must stay
  /// clear of that sum.
  Duration get stallIndicatorDelay;

  /// What the controller does with playback when the app leaves the
  /// foreground, resolved against the platform default.
  ///
  /// Owned here rather than by the host screen so that every embedder of this
  /// package gets the behaviour, and so the "resume only what the policy
  /// paused" bookkeeping lives next to the state it reads.
  VlcBackgroundPolicy get backgroundPolicy;

  /// Whether this controller is currently attached to a native player instance.
  bool get isAttached;

  /// Current playlist items, or an empty list when no playlist is active.
  List<VlcMediaSource> get playlist;

  /// Current playlist index, or `null` when no playlist is active.
  int? get playlistIndex;

  /// Current playlist loop mode.
  VlcPlaylistLoopMode get playlistLoopMode;

  /// Current media source, including a pending source set before attachment.
  VlcMediaSource? get currentMediaSource;

  /// Whether [next] can move to another item without wrapping.
  bool get hasNext;

  /// Whether [previous] can move to another item without wrapping.
  bool get hasPrevious;

  /// Loads a [VlcMediaSource].
  ///
  /// Use this when the item needs HTTP headers, VLC media options, or an
  /// initial seek position. This clears any active playlist.
  Future<void> setMedia(VlcMediaSource source, {bool autoPlay = false});

  /// Caps the reported [VlcPlayerValue.duration] at [cap], for a media whose
  /// length libVLC gets wrong; null lifts the cap from the next report on.
  ///
  /// libVLC reports an HLS master's length as that of the longest playlist it
  /// has loaded, alternative renditions included, selected or not. A subtitle
  /// file wrapped as one segment that claims 99,999 seconds therefore makes a
  /// fifty-minute episode read 27:46:39. A host that has measured the video's
  /// own playlist passes that length here.
  ///
  /// The cap only ever shortens: a shorter report, or an unknown one, is
  /// published as it is. It applies at once and lasts until the next media.
  void setDurationCap(Duration? cap);

  /// Loads a playlist and selects [initialIndex].
  ///
  /// [sources] must be non-empty. When [autoAdvance] is true, the controller
  /// advances after VLC reports that the current item ended. [loopMode] controls
  /// repeat and wrap behavior.
  Future<void> setPlaylist(
    List<VlcMediaSource> sources, {
    int initialIndex = 0,
    bool autoPlay = false,
    bool autoAdvance = true,
    VlcPlaylistLoopMode loopMode = VlcPlaylistLoopMode.none,
  });

  /// Moves to the next playlist item.
  ///
  /// Returns `false` when there is no next item and [playlistLoopMode] is
  /// [VlcPlaylistLoopMode.none]. Throws [StateError] when no playlist is active.
  Future<bool> next({bool autoPlay = true});

  /// Moves to the previous playlist item.
  ///
  /// Returns `false` when there is no previous item and [playlistLoopMode] is
  /// [VlcPlaylistLoopMode.none]. Throws [StateError] when no playlist is active.
  Future<bool> previous({bool autoPlay = true});

  /// Loads the playlist item at [index].
  ///
  /// Throws [StateError] when no playlist is active.
  Future<void> jumpTo(int index, {bool autoPlay = true});

  /// Appends [source] to the active playlist.
  ///
  /// Throws [StateError] when no playlist is active.
  Future<void> addToPlaylist(VlcMediaSource source);

  /// Inserts [source] into the active playlist at [index].
  ///
  /// Throws [StateError] when no playlist is active.
  Future<void> insertIntoPlaylist(int index, VlcMediaSource source);

  /// Removes the playlist item at [index].
  ///
  /// Removing the current item loads the next valid item. If the removed item
  /// was the only item, playback stops and the playlist is cleared.
  Future<void> removeFromPlaylistAt(int index, {bool autoPlay = true});

  /// Clears the active playlist and stops playback when a player is attached.
  Future<void> clearPlaylist();

  /// Shuffles the active playlist.
  ///
  /// When [seed] is provided, the shuffle order is deterministic.
  Future<void> shufflePlaylist({int? seed});

  /// Starts or resumes playback.
  Future<void> play();

  /// Pauses playback.
  Future<void> pause();

  /// Stops playback.
  Future<void> stop();

  /// Seeks to [position].
  ///
  /// [position] must be non-negative. [pendingSeekTarget] moves to it at once.
  /// The engine is sent it at once too, unless another seek went out within
  /// the last [seekMergeWindow] - then the two are merged, and the engine is
  /// sent the latest target once the seeks stop arriving for a window. The
  /// returned future completes once the seek is sent or, merged, taken.
  Future<void> seekTo(Duration position);

  /// How long after a seek has gone to the engine further seeks are held and
  /// merged into one.
  ///
  /// libVLC answers every seek by flushing its decoders and, whenever the
  /// target is not already in its read-ahead, by dropping that and asking the
  /// network for the stream again - over a new connection on HTTP/1.1. It
  /// merges queued seeks only while one is still being processed (VLC 3.0.21
  /// `src/input/input.c`), so six presses of an arrow key, six taps or six
  /// bumps of a gamepad shoulder button became three full resets, a frame
  /// from each flashing past.
  static const Duration seekMergeWindow = Duration(milliseconds: 400);

  /// Where the last seek is going, until the engine gets there; null when no
  /// seek is on its way.
  ///
  /// libVLC keeps reporting the position it left while a seek repositions the
  /// demuxer and refills the buffer - seconds, on a slow network file - so a
  /// scrubber drawn from [VlcPlayerValue.position] alone springs back to where
  /// the viewer was and jumps forward later. Media3 and the browsers report a
  /// seek's target from the moment it is asked for; a scrubber or a clock that
  /// wants to behave the same shows this while it is set.
  /// [VlcPlayerValue.position] itself stays the engine's own throughout, for
  /// everything that must only ever see a place playback reached.
  ///
  /// Set by [seekTo]. Cleared when the engine's position arrives at it - a
  /// little short counts, since seeks land on a keyframe or a segment boundary
  /// - or goes past it in the seek's direction; when the engine can no longer
  /// get there (stopped, ended, failed, new media); and when playback carries
  /// on somewhere else without ever arriving, which is an engine that did not
  /// take the seek at all.
  ValueListenable<Duration?> get pendingSeekTarget;

  /// How many seeks have been asked for on this controller.
  ///
  /// Only ever increases, and increases the moment a seek is requested rather
  /// than when the engine acts on one. A host watching for a dead source needs
  /// that distinction: a seek freezes the reported position while the demuxer
  /// repositions and refills, and on a slow source it can stay frozen for
  /// longer than any sane "nothing is happening" threshold. Counting that as a
  /// dead source reopens the media underneath a viewer who only skipped
  /// forward. Comparing this against a remembered value tells a host the freeze
  /// it is looking at was asked for.
  int get seekRequests;

  /// Sets VLC volume.
  ///
  /// Values are clamped to VLC's `0..200` range.
  Future<void> setVolume(int volume);

  /// Sets playback speed.
  ///
  /// [speed] must be finite and greater than zero. `1.0` is normal speed.
  Future<void> setPlaybackSpeed(double speed);

  /// Changes how video is scaled inside the view, without recreating the
  /// native player. Called by `VlcPlayer` when its `fit` changes.
  Future<void> setFit(VlcVideoFit fit);

  /// Sets the audio playback delay.
  ///
  /// Positive values delay audio; negative values play audio earlier.
  Future<void> setAudioDelay(Duration delay);

  /// Sets the subtitle display delay.
  ///
  /// Positive values delay subtitles; negative values show subtitles earlier.
  Future<void> setSubtitleDelay(Duration delay);

  /// Captures the current video frame as PNG bytes.
  ///
  /// [width] and [height] must be positive when provided.
  Future<Uint8List> takeSnapshot({int? width, int? height});

  /// Returns selectable audio tracks for the current media.
  Future<List<VlcTrackDescription>> getAudioTracks();

  /// Selects an audio track by VLC track [id].
  ///
  /// Use an id returned by [getAudioTracks].
  Future<void> setAudioTrack(int id);

  /// Returns selectable embedded subtitle tracks for the current media.
  Future<List<VlcTrackDescription>> getSubtitleTracks();

  /// Selects an embedded subtitle track by VLC track [id].
  ///
  /// Use an id returned by [getSubtitleTracks].
  Future<void> setSubtitleTrack(int id);

  /// Disables subtitle rendering for the current media.
  Future<void> disableSubtitle();

  /// Asks the engine to add an external subtitle from [uri] and select it.
  ///
  /// [uri] can point to a local file or a remote subtitle URL supported by VLC.
  ///
  /// The future completing does NOT mean the track exists yet. Before
  /// attachment the request is queued and replayed on attach; after it,
  /// libVLC 3 hands the slave to the input thread, so the snapshot that
  /// follows still describes the state from before the add on all five
  /// backends. Wait for [VlcPlayerValue.trackRevision] to move, then re-read
  /// [getSubtitleTracks]; do not treat a list read straight after this call as
  /// authoritative.
  Future<void> addSubtitle(Uri uri);

  /// Returns metadata and discovered track details for the current media.
  Future<VlcMediaInfo> getMediaInfo();

  /// Returns runtime statistics for the current media session.
  Future<VlcMediaStats> getMediaStats();
}

const MethodChannel _methodChannel = MethodChannel('vlc_player');

/// How far short of a seek's target the engine may land and count as there:
/// seeks land on a keyframe or a segment boundary, a little before the
/// millisecond asked for. See `_seekLanded`.
const Duration _kSeekLandsShortBy = Duration(seconds: 3);

/// How far past a seek's target the engine may land and count as there.
const Duration _kSeekLandsLongBy = Duration(milliseconds: 750);

/// How many published positions in a row may move without arriving before a
/// seek is taken as not having happened. Two or three can be reports already
/// on their way when the seek was asked - an earlier step of a chain landing,
/// a tick from the old position - so a handful more than that: about three
/// seconds of playback carrying on at the rate positions are published.
const int _kSeekIgnoredAfterMoves = 12;

class _VlcPlayerController extends VlcPlayerController
    implements VlcPlayerControllerInternals {
  _VlcPlayerController({
    VlcMediaSource? mediaSource,
    this.autoPlay = false,
    List<String> options = const <String>[],
    this.eventThrottleInterval,
    required this.stallIndicatorDelay,
    this.configuredBackgroundPolicy,
  }) : options = List<String>.unmodifiable(options),
       super._() {
    if (eventThrottleInterval case final interval? when interval.isNegative) {
      throw ArgumentError.value(
        eventThrottleInterval,
        'eventThrottleInterval',
        'Must not be negative.',
      );
    }
    if (stallIndicatorDelay <= Duration.zero) {
      throw ArgumentError.value(
        stallIndicatorDelay,
        'stallIndicatorDelay',
        'Must be positive.',
      );
    }
    _pendingMediaSource = mediaSource;
    _pendingAutoPlay = autoPlay;
    // Judged against what is published, not the raw snapshot: a landing held
    // back by the event throttle must not clear the target while the old
    // position is still the one on screen.
    addListener(_watchSeekLanding);
  }

  @override
  final bool autoPlay;

  @override
  final List<String> options;

  @override
  final Duration? eventThrottleInterval;

  @override
  final Duration stallIndicatorDelay;

  /// The host's stated preference, or null to follow the platform.
  final VlcBackgroundPolicy? configuredBackgroundPolicy;

  /// Created on first attach rather than in the constructor.
  ///
  /// [AppLifecycleListener] resolves `WidgetsBinding.instance` eagerly, and a
  /// controller is legitimately built in a plain `flutter_test` `test()` with
  /// no binding at all — configuring one is not the same as playing anything.
  /// There is also nothing to pause before a native player exists.
  AppLifecycleListener? _lifecycleListener;

  /// Whether [backgroundPolicy] is what paused the current playback.
  ///
  /// The whole point of the flag: a viewer who paused by hand and then pressed
  /// Home must come back to a paused player. Resuming unconditionally is the
  /// bug this exists to prevent.
  bool _pausedForBackground = false;

  /// Whether the CURRENT media has actually reached playback.
  ///
  /// [VlcPlayerValue] merges into its predecessor, so straight after
  /// `setMedia` `value.position` still describes the media before it. This is
  /// the flag that tells the two apart, and it is what makes a re-attach able
  /// to trust the live position - see [_mediaForAttach].
  bool _hasPlayedSinceMedia = false;

  /// Whether an audio interruption is what paused the current playback, and
  /// whether it promised to end.
  ///
  /// Set only for [VlcAudioInterruption.focusLostTransient]: a call comes
  /// back, a permanent loss and a yanked pair of headphones do not.
  ///
  /// Tracked apart from [_pausedForBackground] rather than folded into it,
  /// because the two are settled by different events and the interleaving that
  /// matters gets it wrong otherwise. A call arriving and then the call UI
  /// pushing the app away leaves only this one set — the policy stakes its
  /// claim on a player it found playing, and an interrupted player is already
  /// paused — so when focus returns to a backgrounded app, the claim is handed
  /// over deliberately in [_applyInterruption] instead of being assumed.
  ///
  /// Both being set at once is harmless where it can happen, and neither
  /// resume can escape the native focus request: a play that the system
  /// refuses does not start anything, it comes straight back as another
  /// interruption.
  bool _pausedForAudioFocus = false;

  /// Whether the app is currently in the background.
  ///
  /// Distinct from [_pausedForBackground], which only records that the policy
  /// paused something. Media can be opened while the app is away - a cold
  /// magnet resolves for minutes - and that open must not start making noise.
  bool _backgrounded = false;

  int? _viewId;
  int? _textureId;
  VlcMediaSource? _pendingMediaSource;
  bool _pendingAutoPlay = false;

  /// External subtitles requested before a player instance existed.
  ///
  /// [setMedia] already tolerates being called before attachment, so callers
  /// reasonably expect [addSubtitle] to as well — otherwise every caller has to
  /// hand-roll the same "wait until attached" dance. They are flushed in order
  /// once a view or texture is attached, and dropped when new media is set.
  final List<Uri> _pendingSubtitles = <Uri>[];
  List<VlcMediaSource> _playlist = const <VlcMediaSource>[];
  int? _playlistIndex;
  bool _playlistAutoAdvance = false;
  VlcPlaylistLoopMode _playlistLoopMode = VlcPlaylistLoopMode.none;
  StreamSubscription<Object?>? _eventsSubscription;
  Timer? _eventThrottleTimer;
  VlcPlayerValue? _pendingThrottledValue;

  /// The host's measured length for the current media - see [setDurationCap].
  Duration? _durationCap;

  /// What the widget last asked libVLC to crop or stretch to; see
  /// [setVideoGeometry]. Lives on the controller rather than the native player
  /// so a player created later - a reattach - starts with it.
  VlcVideoGeometry _videoGeometry = VlcVideoGeometry.none;

  /// Counts down [stallIndicatorDelay] from the first snapshot whose position
  /// matched the one before it. Armed only while the engine claims to be
  /// running, and disarmed by any movement of the clock.
  Timer? _stallTimer;

  /// The position of the last native snapshot, throttled or not.
  ///
  /// Kept apart from `value.position` on purpose: under [eventThrottleInterval]
  /// the published position lags the engine by up to an interval, and a stall
  /// judged against it would see a frozen clock at every flush.
  Duration? _lastNativePosition;

  final ValueNotifier<Duration?> _pendingSeekTarget = ValueNotifier<Duration?>(
    null,
  );

  /// The published position the pending seek set out from - in a chain of
  /// steps, the previous step's target - so an earlier step landing late is
  /// not taken for this one.
  Duration? _seekOrigin;

  /// The published position when the landing was last checked, and how many
  /// checks in a row have found it moving without arriving. A seek on its way
  /// holds the engine's position still; one that moves and moves without
  /// arriving is playback carrying on somewhere the seek never took it.
  Duration? _seekLastSeen;
  int _seekMovesWithoutLanding = 0;
  bool _isDisposed = false;

  @override
  VlcBackgroundPolicy get backgroundPolicy =>
      configuredBackgroundPolicy ??
      VlcPlayerConfig.platformDefaultBackgroundPolicy;

  @override
  bool get isAttached => _viewId != null;

  @override
  List<VlcMediaSource> get playlist => _playlist;

  @override
  int? get playlistIndex => _playlistIndex;

  @override
  VlcPlaylistLoopMode get playlistLoopMode => _playlistLoopMode;

  @override
  VlcMediaSource? get currentMediaSource => _pendingMediaSource;

  @override
  bool get hasNext => switch (_playlistIndex) {
    final int index => index + 1 < _playlist.length,
    null => false,
  };

  @override
  bool get hasPrevious => switch (_playlistIndex) {
    final int index => index > 0,
    null => false,
  };

  /// Attaches this controller to a platform-view player instance.
  @override
  Future<void> attach(int viewId) async {
    _ensureNotDisposed();
    if (_viewId == viewId) {
      return;
    }

    final oldViewId = _viewId;
    _viewId = null;
    _textureId = null;
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    _cancelPendingThrottledValue();
    _cancelStallTimer();
    if (oldViewId != null) {
      await _disposeNativeView(oldViewId);
    }
    if (_isDisposed) {
      await _disposeNativeView(viewId);
      throw StateError('The controller has been disposed.');
    }

    _viewId = viewId;
    _eventsSubscription = EventChannel(
      'vlc_player/events/$viewId',
    ).receiveBroadcastStream().listen(_handleEvent, onError: _handleEventError);
    _ensureLifecycleListener();
    // Ahead of the media, so its first frame is already the right shape. A
    // new native player has no crop and no aspect of its own, so a fit that
    // needs neither costs no call.
    if (_videoGeometry != VlcVideoGeometry.none) await _sendVideoGeometry();
    _ensureNotDisposed();

    final pendingMediaSource = _pendingMediaSource;
    if (pendingMediaSource != null) {
      await _setMedia(
        _mediaForAttach(pendingMediaSource),
        autoPlay: _pendingAutoPlay,
      );
      _ensureNotDisposed();
    }
    await _flushPendingSubtitles();
  }

  /// Attaches this controller to a texture-backed player instance.
  @override
  @internal
  Future<int> attachTexturePlayer() async {
    _ensureNotDisposed();

    final existingTextureId = _textureId;
    if (_viewId != null && existingTextureId != null) {
      return existingTextureId;
    }

    final oldViewId = _viewId;
    _viewId = null;
    _textureId = null;
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    _cancelPendingThrottledValue();
    _cancelStallTimer();
    if (oldViewId != null) {
      await _disposeNativeView(oldViewId);
    }
    _ensureNotDisposed();

    final response = await _invokeNativeMap('create', <String, Object?>{
      'options': options,
    });
    final viewId = (response?['viewId'] as num?)?.toInt();
    final textureId = (response?['textureId'] as num?)?.toInt();
    if (viewId == null || textureId == null) {
      throw StateError('vlc_player texture creation returned invalid data.');
    }
    if (_isDisposed) {
      await _disposeNativeView(viewId);
      throw StateError('The controller has been disposed.');
    }

    _viewId = viewId;
    _textureId = textureId;
    _eventsSubscription = EventChannel(
      'vlc_player/events/$viewId',
    ).receiveBroadcastStream().listen(_handleEvent, onError: _handleEventError);
    _ensureLifecycleListener();
    // Ahead of the media, so its first frame is already the right shape. A
    // new native player has no crop and no aspect of its own, so a fit that
    // needs neither costs no call.
    if (_videoGeometry != VlcVideoGeometry.none) await _sendVideoGeometry();
    _ensureNotDisposed();

    final pendingMediaSource = _pendingMediaSource;
    if (pendingMediaSource != null) {
      await _setMedia(
        _mediaForAttach(pendingMediaSource),
        autoPlay: _pendingAutoPlay,
      );
      _ensureNotDisposed();
    }
    await _flushPendingSubtitles();

    return textureId;
  }

  /// The media to hand a freshly attached player.
  ///
  /// A *re*-attach — the same controller picking up a surface that was torn
  /// down and rebuilt — would otherwise replay the source from the position it
  /// was originally opened at, dropping a viewer an hour into a film back at
  /// the start. The last position this controller saw is the honest answer.
  ///
  /// The configured start survives while nothing has played, which is the
  /// first attach: that is exactly when [VlcMediaSource.startPosition] carries
  /// a resume point and `value.position` is still zero.
  VlcMediaSource _mediaForAttach(VlcMediaSource source) {
    final position = value.position;
    // Only a session that actually reached playback can improve on the
    // configured start. Two traps this avoids: a viewer who rewound below
    // their resume point would otherwise be thrown forward to it again, and a
    // value sampled right after setMedia still carries the PREVIOUS media's
    // position because VlcPlayerValue merges into its predecessor.
    if (!_hasPlayedSinceMedia || position <= Duration.zero) {
      return source;
    }
    return VlcMediaSource(
      uri: source.uri,
      httpHeaders: source.httpHeaders,
      mediaOptions: source.mediaOptions,
      startPosition: position,
    );
  }

  /// Detaches and disposes the native player instance, if one is attached.
  ///
  /// [viewId] names the view the caller believes it owns; a mismatch is a
  /// no-op. Platform-view teardown is not ordered against creation — the
  /// outgoing element's `dispose` can run after the incoming one has already
  /// attached — so an unqualified call would null out a view that is playing.
  /// Null means "whatever is attached", which is all the texture path can say:
  /// it never learns the id.
  @override
  @internal
  Future<void> detach({int? viewId}) async {
    final attachedViewId = _viewId;
    if (viewId != null && attachedViewId != viewId) {
      return;
    }
    _viewId = null;
    _textureId = null;
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    _cancelPendingThrottledValue();
    _cancelStallTimer();
    if (attachedViewId != null) {
      await _disposeNativeView(attachedViewId);
    }
  }

  /// Starts watching the application lifecycle, once.
  ///
  /// The directional callbacks rather than `onStateChange`, deliberately.
  /// `hidden` is passed through in both directions — leaving is
  /// inactive → hidden and returning is paused → hidden — so a raw state
  /// switch re-arms the background pause on the way back in and then resumes
  /// a player the viewer had stopped by hand. [AppLifecycleListener] already
  /// works out which way the app is travelling; taking its answer is cheaper
  /// than keeping a second copy of the state machine here.
  ///
  /// `onInactive` is deliberately absent. On Android it is what entering
  /// picture-in-picture looks like — the activity pauses while its window
  /// stays on screen and playing — and on desktop it is merely a window that
  /// lost focus.
  void _ensureLifecycleListener() {
    // AppLifecycleListener only reports transitions, so a controller attached
    // while the app is already away would never learn it. Seed from the
    // binding's current answer before subscribing.
    final current = WidgetsBinding.instance.lifecycleState;
    _backgrounded =
        current == AppLifecycleState.paused ||
        current == AppLifecycleState.hidden ||
        current == AppLifecycleState.detached;
    _lifecycleListener ??= AppLifecycleListener(
      onHide: _pauseForBackground,
      onPause: _pauseForBackground,
      onResume: _resumeFromBackground,
    );
  }

  void _pauseForBackground() {
    if (_isDisposed) return;
    // Recorded even when there is nothing to pause yet. Resolution can outlast
    // the app going away, and the open that follows has to know.
    _backgrounded = true;
    if (backgroundPolicy != VlcBackgroundPolicy.pause ||
        _pausedForBackground ||
        _viewId == null ||
        !value.isPlaying) {
      return;
    }
    _pausedForBackground = true;
    // Not the public pause(): that one is the user's, and clears the flag this
    // just set. Failures are swallowed because a player that has already gone
    // away has, for this purpose, done what was asked.
    unawaited(_invoke('pause').catchError((Object _) {}));
  }

  void _resumeFromBackground() {
    if (_isDisposed) return;
    _backgrounded = false;
    if (!_pausedForBackground) return;
    _pausedForBackground = false;
    if (_viewId == null) {
      return;
    }
    unawaited(_invoke('play').catchError((Object _) {}));
  }

  /// Mirrors a native audio interruption into this controller's bookkeeping.
  ///
  /// The engine is already paused, ducked or restored by the time this runs:
  /// audio focus has to be honoured in the instant it moves, not a channel
  /// round trip later. What the native side cannot answer is who owns the
  /// resume, because that depends on the app lifecycle and on
  /// [backgroundPolicy], both of which live here. So it reports, and this
  /// decides.
  ///
  /// Never through the public [play] and [pause]: those mean "the viewer
  /// decided" and clear [_pausedForBackground]. A phone call is not a
  /// decision the viewer made.
  void _applyInterruption(
    VlcAudioInterruption previous,
    VlcAudioInterruption next,
  ) {
    if (_isDisposed || previous == next) return;

    if (next != VlcAudioInterruption.none) {
      _pausedForAudioFocus = next == VlcAudioInterruption.focusLostTransient;
      return;
    }

    if (!_pausedForAudioFocus) return;
    _pausedForAudioFocus = false;
    if (_viewId == null) {
      return;
    }
    if (_backgrounded && backgroundPolicy == VlcBackgroundPolicy.pause) {
      // The call ended while the app is still away. Playing here is exactly
      // the noise nobody asked for, so the claim is handed to the background
      // policy and the trip back to the foreground settles it.
      _pausedForBackground = true;
      return;
    }
    unawaited(_invoke('play').catchError((Object _) {}));
  }

  @override
  Future<void> setMedia(VlcMediaSource source, {bool autoPlay = false}) async {
    _ensureNotDisposed();
    // New media invalidates side-car subtitles queued for the old one.
    _pendingSubtitles.clear();
    final previousPlaylist = _playlist;
    final previousPlaylistIndex = _playlistIndex;
    final previousPlaylistAutoAdvance = _playlistAutoAdvance;
    final previousPlaylistLoopMode = _playlistLoopMode;
    final previousMediaSource = _pendingMediaSource;
    final previousAutoPlay = _pendingAutoPlay;
    _clearPlaylist();
    try {
      await _setMedia(source, autoPlay: autoPlay);
    } catch (_) {
      _playlist = previousPlaylist;
      _playlistIndex = previousPlaylistIndex;
      _playlistAutoAdvance = previousPlaylistAutoAdvance;
      _playlistLoopMode = previousPlaylistLoopMode;
      _pendingMediaSource = previousMediaSource;
      _pendingAutoPlay = previousAutoPlay;
      rethrow;
    }
  }

  @override
  void setDurationCap(Duration? cap) {
    // Measured off the main path, so it can land after the host let go.
    if (_isDisposed) return;
    _durationCap = cap;
    final pending = _pendingThrottledValue;
    if (pending != null) _pendingThrottledValue = _capDuration(pending);
    final capped = _capDuration(value);
    if (capped != value) value = capped;
  }

  @override
  @internal
  void setVideoGeometry(VlcVideoGeometry geometry) {
    if (_isDisposed || geometry == _videoGeometry) return;
    _videoGeometry = geometry;
    if (_viewId != null) unawaited(_sendVideoGeometry());
  }

  /// Best effort: a backend that does not know the call still plays, only
  /// with subtitles laid out for the whole picture.
  Future<void> _sendVideoGeometry() async {
    final viewId = _viewId;
    if (viewId == null) return;
    final geometry = _videoGeometry;
    try {
      await _invokeNative<void>('setVideoGeometry', <String, Object?>{
        'viewId': viewId,
        'crop': geometry.crop,
        'aspectRatio': geometry.aspectRatio,
      });
    } catch (error) {
      if (kDebugMode) debugPrint('vlc_player: setVideoGeometry failed: $error');
    }
  }

  VlcPlayerValue _capDuration(VlcPlayerValue next) {
    final cap = _durationCap;
    if (cap == null || next.duration <= cap) return next;
    return next.copyWith(duration: cap);
  }

  @override
  Future<void> setPlaylist(
    List<VlcMediaSource> sources, {
    int initialIndex = 0,
    bool autoPlay = false,
    bool autoAdvance = true,
    VlcPlaylistLoopMode loopMode = VlcPlaylistLoopMode.none,
  }) async {
    _ensureNotDisposed();
    if (sources.isEmpty) {
      throw ArgumentError.value(sources, 'sources', 'Must be non-empty.');
    }
    RangeError.checkValidIndex(initialIndex, sources, 'initialIndex');

    final previousPlaylist = _playlist;
    final previousPlaylistIndex = _playlistIndex;
    final previousPlaylistAutoAdvance = _playlistAutoAdvance;
    final previousPlaylistLoopMode = _playlistLoopMode;
    final previousMediaSource = _pendingMediaSource;
    final previousAutoPlay = _pendingAutoPlay;
    _playlist = List<VlcMediaSource>.unmodifiable(sources);
    _playlistIndex = initialIndex;
    _playlistAutoAdvance = autoAdvance;
    _playlistLoopMode = loopMode;
    try {
      await _setMedia(_playlist[initialIndex], autoPlay: autoPlay);
    } catch (_) {
      _playlist = previousPlaylist;
      _playlistIndex = previousPlaylistIndex;
      _playlistAutoAdvance = previousPlaylistAutoAdvance;
      _playlistLoopMode = previousPlaylistLoopMode;
      _pendingMediaSource = previousMediaSource;
      _pendingAutoPlay = previousAutoPlay;
      rethrow;
    }
  }

  @override
  Future<bool> next({bool autoPlay = true}) {
    return _moveInPlaylist(1, autoPlay: autoPlay);
  }

  @override
  Future<bool> previous({bool autoPlay = true}) {
    return _moveInPlaylist(-1, autoPlay: autoPlay);
  }

  @override
  Future<void> jumpTo(int index, {bool autoPlay = true}) async {
    _ensureActivePlaylist();
    RangeError.checkValidIndex(index, _playlist, 'index');
    if (index == _playlistIndex) {
      return;
    }
    await _loadPlaylistIndex(index, autoPlay: autoPlay);
  }

  @override
  Future<void> addToPlaylist(VlcMediaSource source) {
    return insertIntoPlaylist(_playlist.length, source);
  }

  @override
  Future<void> insertIntoPlaylist(int index, VlcMediaSource source) async {
    _ensureActivePlaylist();
    RangeError.checkValueInInterval(index, 0, _playlist.length, 'index');
    final currentIndex = _playlistIndex!;
    final nextPlaylist = <VlcMediaSource>[..._playlist]..insert(index, source);
    _playlist = List<VlcMediaSource>.unmodifiable(nextPlaylist);
    if (index <= currentIndex) {
      _playlistIndex = currentIndex + 1;
    }
  }

  @override
  Future<void> removeFromPlaylistAt(int index, {bool autoPlay = true}) async {
    _ensureActivePlaylist();
    RangeError.checkValidIndex(index, _playlist, 'index');

    final previousPlaylist = _playlist;
    final previousPlaylistIndex = _playlistIndex;
    final previousMediaSource = _pendingMediaSource;
    final previousAutoPlay = _pendingAutoPlay;
    final currentIndex = previousPlaylistIndex!;
    final nextPlaylist = <VlcMediaSource>[..._playlist]..removeAt(index);

    if (nextPlaylist.isEmpty) {
      await _stopIfAttached();
      _clearPlaylist();
      _pendingMediaSource = null;
      _pendingAutoPlay = false;
      return;
    }

    _playlist = List<VlcMediaSource>.unmodifiable(nextPlaylist);
    if (index < currentIndex) {
      _playlistIndex = currentIndex - 1;
      return;
    }
    if (index > currentIndex) {
      _playlistIndex = currentIndex;
      return;
    }

    final nextIndex = math.min(index, nextPlaylist.length - 1);
    _playlistIndex = nextIndex;
    try {
      await _setMedia(_playlist[nextIndex], autoPlay: autoPlay);
    } catch (_) {
      _playlist = previousPlaylist;
      _playlistIndex = previousPlaylistIndex;
      _pendingMediaSource = previousMediaSource;
      _pendingAutoPlay = previousAutoPlay;
      rethrow;
    }
  }

  @override
  Future<void> clearPlaylist() async {
    _ensureNotDisposed();
    if (_playlistIndex == null) {
      return;
    }
    await _stopIfAttached();
    _clearPlaylist();
    _pendingMediaSource = null;
    _pendingAutoPlay = false;
  }

  @override
  Future<void> shufflePlaylist({int? seed}) async {
    _ensureActivePlaylist();
    final currentSource = currentMediaSource;
    final random = seed == null ? math.Random() : math.Random(seed);
    final nextPlaylist = <VlcMediaSource>[..._playlist]..shuffle(random);
    _playlist = List<VlcMediaSource>.unmodifiable(nextPlaylist);
    _playlistIndex = currentSource == null
        ? 0
        : _playlist
              .indexOf(currentSource)
              .clamp(0, _playlist.length - 1)
              .toInt();
  }

  Future<bool> _moveInPlaylist(int delta, {required bool autoPlay}) async {
    _ensureActivePlaylist();
    final index = _playlistIndex!;

    final nextIndex = index + delta;
    if (nextIndex < 0 || nextIndex >= _playlist.length) {
      if (_playlistLoopMode != VlcPlaylistLoopMode.loopAll) {
        return false;
      }
      return _loadPlaylistIndex(
        nextIndex < 0 ? _playlist.length - 1 : 0,
        autoPlay: autoPlay,
      );
    }

    return _loadPlaylistIndex(nextIndex, autoPlay: autoPlay);
  }

  Future<bool> _loadPlaylistIndex(
    int nextIndex, {
    required bool autoPlay,
  }) async {
    final index = _playlistIndex;
    if (index == null) {
      throw StateError('No playlist has been set.');
    }

    _playlistIndex = nextIndex;
    final previousMediaSource = _pendingMediaSource;
    final previousAutoPlay = _pendingAutoPlay;
    try {
      await _setMedia(_playlist[nextIndex], autoPlay: autoPlay);
    } catch (_) {
      _playlistIndex = index;
      _pendingMediaSource = previousMediaSource;
      _pendingAutoPlay = previousAutoPlay;
      rethrow;
    }
    return true;
  }

  Future<void> _setMedia(
    VlcMediaSource source, {
    required bool autoPlay,
  }) async {
    _ensureNotDisposed();
    // A fresh media has not played yet, whatever the merged value still says.
    // The stall clock goes with it: the position it was watching belongs to
    // the media on its way out, and the opening buffer of the new one is the
    // startup spinner's job, not this one's.
    _hasPlayedSinceMedia = false;
    _cancelStallTimer();
    // A seek's target belongs to the media it was asked of.
    _clearPendingSeek();
    _dropMergedSeek();
    // A measured length belongs to the media it was measured on.
    _durationCap = null;
    // Opening while the app is away must not start audio nobody can stop:
    // there is no notification and no lock-screen control behind this yet.
    // The policy's claim is staked here so the return trip resumes it.
    if (autoPlay &&
        _backgrounded &&
        backgroundPolicy == VlcBackgroundPolicy.pause) {
      autoPlay = false;
      _pausedForBackground = true;
    }
    _pendingMediaSource = source;
    _pendingAutoPlay = autoPlay;

    final viewId = _viewId;
    if (viewId == null) {
      return;
    }

    await _invokeNative<void>(
      'setSource',
      _sourceArguments(viewId, source, autoPlay: autoPlay),
    );
  }

  void _clearPlaylist() {
    _playlist = const <VlcMediaSource>[];
    _playlistIndex = null;
    _playlistAutoAdvance = false;
    _playlistLoopMode = VlcPlaylistLoopMode.none;
  }

  void _ensureActivePlaylist() {
    _ensureNotDisposed();
    if (_playlistIndex == null) {
      throw StateError('No playlist has been set.');
    }
  }

  // play/pause/stop are the deliberate-intent entry points — the on-screen
  // button, a remote, and in due course the media session and the audio-focus
  // handler. Any of them settles the background question on its own terms, so
  // they clear the policy's claim on the next resume: a viewer who pressed
  // play from a notification while the app was hidden has said what they want.
  @override
  Future<void> play() {
    // The background claim goes, because the viewer has settled the question
    // the trip back to the foreground would otherwise answer.
    //
    // The audio-focus claim stays. "Play" and "resume when the call ends" are
    // the same wish, and on Android a play made during a call is refused
    // outright — that refusal comes back as an interruption, and the delayed
    // grant that follows is the only thing that will ever start this playing.
    _pausedForBackground = false;
    return _invoke('play');
  }

  @override
  Future<void> pause() {
    _clearAutomaticPauseClaims();
    // A paused player is not stalled, it is paused. The flag itself is cleared
    // by the paused snapshot when it arrives; what must not happen is the
    // timer firing in the gap before it and painting a spinner over a still
    // frame the viewer asked for.
    _cancelStallTimer();
    return _invoke('pause');
  }

  @override
  Future<void> stop() {
    _clearAutomaticPauseClaims();
    _cancelStallTimer();
    return _invoke('stop');
  }

  /// Drops every claim that would otherwise start playback on its own.
  ///
  /// Asking for silence answers both questions at once: a viewer who pauses
  /// while the app is hidden, or during a phone call, must not have the film
  /// started again by the return trip or by the end of the call.
  void _clearAutomaticPauseClaims() {
    _pausedForBackground = false;
    _pausedForAudioFocus = false;
  }

  int _seekRequests = 0;

  @override
  int get seekRequests => _seekRequests;

  @override
  Future<void> seekTo(Duration position) {
    if (position.isNegative) {
      throw ArgumentError.value(position, 'position', 'Must be non-negative.');
    }
    _seekRequests += 1;
    // After a rebuffer, the gap between a seek and the first frame at the new
    // position is the stall a viewer feels most, so the clock restarts here
    // rather than waiting for a snapshot to notice nothing moved.
    //
    // The comparison baseline moves to the target as well. Every backend
    // reports the requested time straight after a seek, before a frame has
    // been decoded there; measured against the OLD position that report looks
    // like movement and would disarm the timer, pushing the spinner out by a
    // whole extra delay. This is a private baseline for the clock, never the
    // published position - a viewer who scrubs still sees the engine's own
    // position, and the host's resume point never records a place the engine
    // did not reach.
    _cancelStallTimer();
    if (_isRunning((_pendingThrottledValue ?? value).state)) {
      _lastNativePosition = position;
      _armStallTimer();
    }
    _seekOrigin = _pendingSeekTarget.value ?? value.position;
    _seekLastSeen = value.position;
    _seekMovesWithoutLanding = 0;
    _pendingSeekTarget.value = position;
    return _sendOrMergeSeek(position);
  }

  /// When a seek last went to the engine, and where to.
  ///
  /// A time rather than an open timer, so a seek on its own leaves nothing
  /// running behind it; a timer exists only while a merged seek waits.
  DateTime? _seekSentAt;
  Duration? _seekSentTarget;

  /// The latest seek asked for inside the window, and the timer that sends it
  /// once the seeks stop arriving.
  Duration? _mergedSeek;
  Timer? _mergedSeekTimer;

  /// The first seek of a burst goes at once; the rest move the target and
  /// restart the window. See [VlcPlayerController.seekMergeWindow].
  ///
  /// A merged seek completes as soon as it is taken. Its caller has nothing
  /// to wait for - the target is already published - and holding it for the
  /// window would hang it outright wherever time does not advance on its own.
  Future<void> _sendOrMergeSeek(Duration position) {
    const window = VlcPlayerController.seekMergeWindow;
    final now = clock.now();
    final sentAt = _seekSentAt;
    final inBurst =
        _mergedSeekTimer != null ||
        (sentAt != null && now.difference(sentAt) < window);
    if (!inBurst) {
      _seekSentAt = now;
      _seekSentTarget = position;
      return _sendSeek(position);
    }
    _mergedSeek = position;
    _mergedSeekTimer?.cancel();
    _mergedSeekTimer = Timer(window, _sendMergedSeek);
    return Future<void>.value();
  }

  void _sendMergedSeek() {
    _mergedSeekTimer = null;
    final target = _mergedSeek;
    _mergedSeek = null;
    // A burst that ends where it began - right, right, left - has nothing to
    // send: the engine already has that target, and a second seek there
    // would flush and refill for nothing.
    if (target == null || target == _seekSentTarget) return;
    // Sending restarts the window, so a burst that carries on straight after
    // is merged again rather than sent press by press.
    _seekSentAt = clock.now();
    _seekSentTarget = target;
    // The engine only has the seek from now, so the landing watcher's count
    // of reports that moved without arriving starts here, not at the press.
    _seekMovesWithoutLanding = 0;
    unawaited(_sendSeek(target));
  }

  /// Forgets a merged seek that has not gone out, and the last one that did:
  /// both belong to media that is going away, and the first seek on the next
  /// one goes at once.
  void _dropMergedSeek() {
    _mergedSeekTimer?.cancel();
    _mergedSeekTimer = null;
    _mergedSeek = null;
    _seekSentAt = null;
    _seekSentTarget = null;
  }

  Future<void> _sendSeek(Duration position) =>
      _invoke('seekTo', <String, Object?>{'position': position.inMilliseconds});

  @override
  ValueListenable<Duration?> get pendingSeekTarget => _pendingSeekTarget;

  /// Clears [pendingSeekTarget] once the published value shows the engine has
  /// arrived, cannot arrive, or has carried on without the seek.
  void _watchSeekLanding() {
    final target = _pendingSeekTarget.value;
    final origin = _seekOrigin;
    if (target == null || origin == null) return;
    final published = value;
    if (!_canStillLand(published.state) ||
        _seekLanded(published.position, target: target, origin: origin)) {
      _clearPendingSeek();
      return;
    }
    final last = _seekLastSeen;
    _seekLastSeen = published.position;
    if (last == null || published.position == last) {
      // Still: the engine is repositioning or refilling, which is what a seek
      // on its way looks like.
      _seekMovesWithoutLanding = 0;
      return;
    }
    _seekMovesWithoutLanding += 1;
    if (_seekMovesWithoutLanding >= _kSeekIgnoredAfterMoves) {
      _clearPendingSeek();
    }
  }

  /// Whether [position] shows the engine has taken the seek from [origin] to
  /// [target]: it is at the target - a little short allowed, because seeks
  /// land on a keyframe or a segment boundary - or it has gone past the
  /// target in the direction of the seek.
  ///
  /// Anything else holds, and that is what matters in a chain of D-pad steps:
  /// the report of an earlier step landing is short of this one's target, not
  /// at it.
  static bool _seekLanded(
    Duration position, {
    required Duration target,
    required Duration origin,
  }) {
    final asked = target - origin;
    // Short by at most half the step, so a report from where a short step
    // set out cannot pass for its landing.
    final half = asked.abs() ~/ 2;
    final shortBy = half < _kSeekLandsShortBy ? half : _kSeekLandsShortBy;
    final early = asked.isNegative ? _kSeekLandsLongBy : shortBy;
    final late = asked.isNegative ? shortBy : _kSeekLandsLongBy;
    if (position >= target - early && position <= target + late) return true;
    if (asked == Duration.zero) return false;
    final travelled = position - origin;
    return travelled.isNegative == asked.isNegative &&
        travelled.abs() >= asked.abs();
  }

  /// A paused seek still lands; a stopped, ended, errored or idle engine
  /// never will.
  static bool _canStillLand(VlcPlaybackState state) {
    return switch (state) {
      VlcPlaybackState.opening ||
      VlcPlaybackState.buffering ||
      VlcPlaybackState.playing ||
      VlcPlaybackState.paused => true,
      VlcPlaybackState.idle ||
      VlcPlaybackState.stopped ||
      VlcPlaybackState.ended ||
      VlcPlaybackState.error => false,
    };
  }

  void _clearPendingSeek() {
    _seekOrigin = null;
    _seekLastSeen = null;
    _seekMovesWithoutLanding = 0;
    _pendingSeekTarget.value = null;
  }

  @override
  Future<void> setVolume(int volume) {
    return _invoke('setVolume', <String, Object?>{
      'volume': volume.clamp(0, 200),
    });
  }

  @override
  Future<void> setPlaybackSpeed(double speed) {
    if (!speed.isFinite || speed <= 0) {
      throw ArgumentError.value(
        speed,
        'speed',
        'Must be finite and greater than zero.',
      );
    }
    return _invoke('setPlaybackSpeed', <String, Object?>{'speed': speed});
  }

  @override
  Future<void> setFit(VlcVideoFit fit) {
    return _invoke('setFit', <String, Object?>{'fit': fit.name});
  }

  @override
  Future<void> setAudioDelay(Duration delay) {
    return _invoke('setAudioDelay', <String, Object?>{
      'delay': delay.inMicroseconds,
    });
  }

  @override
  Future<void> setSubtitleDelay(Duration delay) {
    return _invoke('setSubtitleDelay', <String, Object?>{
      'delay': delay.inMicroseconds,
    });
  }

  @override
  Future<Uint8List> takeSnapshot({int? width, int? height}) async {
    if (width != null && width <= 0) {
      throw ArgumentError.value(width, 'width', 'Must be positive.');
    }
    if (height != null && height <= 0) {
      throw ArgumentError.value(height, 'height', 'Must be positive.');
    }
    final data = await _invokeFor<Uint8List>('takeSnapshot', <String, Object?>{
      'width': ?width,
      'height': ?height,
    });
    if (data == null || data.isEmpty) {
      throw StateError('vlc_player snapshot returned no image data.');
    }
    return data;
  }

  @override
  Future<List<VlcTrackDescription>> getAudioTracks() async {
    final tracks = await _invokeFor<List<Object?>>('getAudioTracks');
    return _trackDescriptionsFrom(tracks);
  }

  @override
  Future<void> setAudioTrack(int id) {
    if (id < 0) {
      throw ArgumentError.value(id, 'id', 'Must be non-negative.');
    }
    return _invoke('setAudioTrack', <String, Object?>{'id': id});
  }

  @override
  Future<List<VlcTrackDescription>> getSubtitleTracks() async {
    final tracks = await _invokeFor<List<Object?>>('getSubtitleTracks');
    return _trackDescriptionsFrom(tracks);
  }

  @override
  Future<void> setSubtitleTrack(int id) {
    if (id < 0) {
      throw ArgumentError.value(id, 'id', 'Must be non-negative.');
    }
    return _invoke('setSubtitleTrack', <String, Object?>{'id': id});
  }

  @override
  Future<void> disableSubtitle() => _invoke('disableSubtitle');

  @override
  Future<void> addSubtitle(Uri uri) async {
    _ensureNotDisposed();
    final value = uri.toString();
    if (value.isEmpty) {
      throw ArgumentError.value(uri, 'uri', 'Must be non-empty.');
    }
    if (_viewId == null) {
      _pendingSubtitles.add(uri);
      return;
    }
    await _invoke('addSubtitle', <String, Object?>{'uri': value});
  }

  /// Applies subtitles queued before attachment, in the order requested.
  ///
  /// A failure here must not take down attachment: the video is playable
  /// without a side-car subtitle, so a bad URI is dropped rather than thrown.
  Future<void> _flushPendingSubtitles() async {
    if (_pendingSubtitles.isEmpty || _viewId == null) {
      return;
    }
    final pending = List<Uri>.of(_pendingSubtitles);
    _pendingSubtitles.clear();
    for (final uri in pending) {
      if (_isDisposed || _viewId == null) {
        return;
      }
      try {
        await _invoke('addSubtitle', <String, Object?>{'uri': uri.toString()});
      } catch (_) {
        // Ignored on purpose - see above.
      }
    }
  }

  @override
  Future<VlcMediaInfo> getMediaInfo() async {
    final info = await _invokeFor<Map<Object?, Object?>>('getMediaInfo');
    return VlcMediaInfo.fromMap(info ?? const <Object?, Object?>{});
  }

  @override
  Future<VlcMediaStats> getMediaStats() async {
    final stats = await _invokeFor<Map<Object?, Object?>>('getMediaStats');
    return VlcMediaStats.fromMap(stats ?? const <Object?, Object?>{});
  }

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) {
    return _invokeFor<void>(method, arguments);
  }

  Future<T?> _invokeFor<T>(String method, [Map<String, Object?>? arguments]) {
    return _invokeNative<T>(method, _attachedArguments(arguments));
  }

  Future<void> _stopIfAttached() {
    if (_viewId == null) {
      return Future<void>.value();
    }
    return _invoke('stop');
  }

  Map<String, Object?> _attachedArguments([Map<String, Object?>? arguments]) {
    _ensureNotDisposed();
    final viewId = _viewId;
    if (viewId == null) {
      throw StateError('The controller is not attached to a VlcPlayer.');
    }

    return <String, Object?>{'viewId': viewId, ...?arguments};
  }

  /// Builds every `setSource` payload, so headers can never desync from the
  /// media they belong to.
  ///
  /// HTTP headers are translated to libVLC options **here**, once, rather than
  /// in each of the five native backends. libVLC can transmit only User-Agent
  /// and Referer (see vlc_http_headers.dart); the natives are handed the raw
  /// map as well, but only for mechanisms that are genuinely platform-specific.
  Map<String, Object?> _sourceArguments(
    int viewId,
    VlcMediaSource source, {
    required bool autoPlay,
  }) {
    final headerOptions = vlcHeaderOptions(source.httpHeaders);
    final mediaOptions = <String>[...headerOptions, ...source.mediaOptions];

    assert(() {
      final dropped = unsupportedVlcHeaders(source.httpHeaders);
      if (dropped.isNotEmpty) {
        debugPrint(
          'vlc_player: libVLC cannot send these headers, so they were dropped '
          'for ${source.uri}: ${dropped.join(', ')}. Proxy the media and '
          'inject them upstream if the server requires them.',
        );
      }
      return true;
    }());

    return <String, Object?>{
      'viewId': viewId,
      'uri': source.uri.toString(),
      'autoPlay': autoPlay,
      'httpHeaders': source.httpHeaders,
      if (mediaOptions.isNotEmpty) 'mediaOptions': mediaOptions,
      if (source.startPosition > Duration.zero)
        'startPosition': source.startPosition.inMilliseconds,
    };
  }

  Future<T?> _invokeNative<T>(String method, Map<String, Object?> arguments) {
    return _mapPlatformException(
      () => _methodChannel.invokeMethod<T>(method, arguments),
    );
  }

  Future<Map<String, Object?>?> _invokeNativeMap(
    String method,
    Map<String, Object?> arguments,
  ) {
    return _mapPlatformException(
      () => _methodChannel.invokeMapMethod<String, Object?>(method, arguments),
    );
  }

  static Future<T> _mapPlatformException<T>(
    Future<T> Function() operation,
  ) async {
    try {
      return await operation();
    } on PlatformException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        VlcPlayerException.fromPlatformException(error),
        stackTrace,
      );
    }
  }

  static List<VlcTrackDescription> _trackDescriptionsFrom(Object? value) {
    if (value is! Iterable) {
      return const <VlcTrackDescription>[];
    }
    return value
        .whereType<Map>()
        .map(
          (track) =>
              VlcTrackDescription.fromMap(track.cast<Object?, Object?>()),
        )
        .toList(growable: false);
  }

  Future<void> _disposeNativeView(int viewId) {
    return _methodChannel.invokeMethod<void>('dispose', <String, Object?>{
      'viewId': viewId,
    });
  }

  void _handleEvent(Object? event) {
    if (_isDisposed) {
      return;
    }
    final previousValue = _pendingThrottledValue ?? value;
    final nextValue = _observeStall(
      _capDuration(VlcPlayerValue.fromEvent(event, previousValue)),
    );
    _setValueFromEvent(previousValue, nextValue);
    _applyInterruption(previousValue.interruption, nextValue.interruption);
    if (_playlistAutoAdvance &&
        previousValue.state != VlcPlaybackState.ended &&
        nextValue.state == VlcPlaybackState.ended) {
      if (_playlistLoopMode == VlcPlaylistLoopMode.loopOne) {
        final current = _pendingMediaSource;
        if (current != null) {
          _runAutoAdvance(_setMedia(current, autoPlay: true));
        }
      } else if (hasNext || _playlistLoopMode == VlcPlaylistLoopMode.loopAll) {
        _runAutoAdvance(next().then<void>((_) {}));
      }
    }
  }

  void _runAutoAdvance(Future<void> operation) {
    unawaited(
      operation.catchError((Object error, StackTrace stackTrace) {
        _handleAutoAdvanceError(error);
      }),
    );
  }

  void _handleAutoAdvanceError(Object error) {
    if (_isDisposed) {
      return;
    }
    final playerError = error is VlcPlayerException
        ? error.error
        : error is PlatformException
        ? VlcPlayerError.fromPlatformException(error)
        : VlcPlayerError(
            code: VlcPlayerErrorCode.playbackError,
            message: error.toString(),
          );
    _setPlayerError(playerError);
  }

  void _handleEventError(Object error) {
    if (_isDisposed) {
      return;
    }
    final playerError = error is PlatformException
        ? VlcPlayerError.fromPlatformException(error)
        : VlcPlayerError(
            code: VlcPlayerErrorCode.eventChannelError,
            message: error.toString(),
          );
    _setPlayerError(playerError);
  }

  void _setPlayerError(VlcPlayerError playerError) {
    _cancelPendingThrottledValue();
    _cancelStallTimer();
    value = value.copyWith(
      state: VlcPlaybackState.error,
      error: playerError,
      errorDescription: playerError.message,
    );
  }

  void _setValueFromEvent(
    VlcPlayerValue previousValue,
    VlcPlayerValue nextValue,
  ) {
    if (nextValue == previousValue) {
      return;
    }
    if (!_shouldThrottleEvent(previousValue, nextValue)) {
      _setValueImmediately(nextValue);
      return;
    }
    _pendingThrottledValue = nextValue;
    _eventThrottleTimer ??= Timer(eventThrottleInterval!, _flushThrottledValue);
  }

  bool _shouldThrottleEvent(
    VlcPlayerValue previousValue,
    VlcPlayerValue nextValue,
  ) {
    final interval = eventThrottleInterval;
    if (interval == null || interval.inMicroseconds == 0) {
      return false;
    }
    return previousValue.state == nextValue.state &&
        previousValue.volume == nextValue.volume &&
        previousValue.playbackSpeed == nextValue.playbackSpeed &&
        previousValue.audioDelay == nextValue.audioDelay &&
        previousValue.subtitleDelay == nextValue.subtitleDelay &&
        previousValue.isReady == nextValue.isReady &&
        previousValue.isSeekable == nextValue.isSeekable &&
        previousValue.isLive == nextValue.isLive &&
        // A stall flag changing is the whole event, not a progress tick that
        // can wait for the next flush.
        previousValue.isStalled == nextValue.isStalled &&
        // Likewise a track switch or a track list changing shape: the panel
        // that asked for it is waiting on this exact value, and it is not a
        // progress tick.
        previousValue.activeAudioTrackId == nextValue.activeAudioTrackId &&
        previousValue.activeSubtitleTrackId ==
            nextValue.activeSubtitleTrackId &&
        previousValue.trackRevision == nextValue.trackRevision &&
        previousValue.interruption == nextValue.interruption &&
        previousValue.videoSize == nextValue.videoSize &&
        previousValue.error == nextValue.error &&
        previousValue.errorDescription == nextValue.errorDescription;
  }

  void _setValueImmediately(VlcPlayerValue nextValue) {
    _cancelPendingThrottledValue();
    value = nextValue;
  }

  void _flushThrottledValue() {
    final pendingValue = _pendingThrottledValue;
    _eventThrottleTimer = null;
    _pendingThrottledValue = null;
    if (!_isDisposed && pendingValue != null) {
      value = pendingValue;
    }
  }

  void _cancelPendingThrottledValue() {
    _eventThrottleTimer?.cancel();
    _eventThrottleTimer = null;
    _pendingThrottledValue = null;
  }

  /// Reads the position clock in [next] and returns what should be published.
  ///
  /// Runs on every native snapshot, before the equality and throttle gates,
  /// because a snapshot identical to the last one is precisely the evidence a
  /// stall is made of - it must arm the timer even though it publishes
  /// nothing.
  ///
  /// "Moved" rather than "advanced", deliberately: a seek backwards lands the
  /// clock below where it was and a later snapshot from there is progress. A
  /// strictly-greater test would hold the spinner up until playback overtook
  /// the pre-seek position.
  VlcPlayerValue _observeStall(VlcPlayerValue next) {
    final moved = _lastNativePosition != next.position;
    _lastNativePosition = next.position;
    // Set here rather than on publish so that throttled progress ticks count:
    // under an event throttle the first snapshot with a real position is
    // usually coalesced, and a flag that only immediate publishes could set
    // would leave a re-attach unable to trust the live position and this
    // clock unable to arm at all.
    if (next.position > Duration.zero) _hasPlayedSinceMedia = true;

    if (!_isRunning(next.state)) {
      // Paused, stopped, ended, error, opening: none of these is a stall, and
      // the flag clears in this same publish rather than a frame later.
      _cancelStallTimer();
      return next.isStalled ? next.copyWith(isStalled: false) : next;
    }
    if (moved) {
      // Movement clears the flag - and RESTARTS the countdown rather than
      // cancelling it. Every native except Android suppresses a snapshot
      // identical to the last one it sent, so a real freeze does not arrive
      // as a repeated position: it arrives as silence. The only way to see
      // that silence is a deadline measured from the last snapshot that
      // moved. Gated the same way as the frozen path: a clock that has never
      // run - a live stream, the pre-first-frame buffer - is not stalling.
      if (_hasPlayedSinceMedia) {
        _restartStallTimer();
      } else {
        _cancelStallTimer();
      }
      return next.isStalled ? next.copyWith(isStalled: false) : next;
    }
    // A clock that has not moved yet is not a stall: a live stream may never
    // report movement, and before the first frame the startup buffer owns the
    // spinner. Only a clock that once ran and has now stopped qualifies.
    if (_hasPlayedSinceMedia) {
      _armStallTimer();
    }
    return next;
  }

  /// Whether [state] claims the engine is producing frames, which is the only
  /// claim a frozen clock can contradict.
  static bool _isRunning(VlcPlaybackState state) {
    return state == VlcPlaybackState.playing ||
        state == VlcPlaybackState.buffering;
  }

  /// Starts the countdown if it is not already running. Never restarts it: on
  /// a native that repeats a frozen position (Android), the stall began at the
  /// first frozen snapshot, not the latest.
  void _armStallTimer() {
    _stallTimer ??= Timer(stallIndicatorDelay, _markStalled);
  }

  /// Restarts the countdown from now. Used on every moved snapshot, so that
  /// the deadline always means "nothing has moved for stallIndicatorDelay" -
  /// which is what a stall looks like on the natives that go silent.
  void _restartStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = Timer(stallIndicatorDelay, _markStalled);
  }

  void _cancelStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  void _markStalled() {
    _stallTimer = null;
    if (_isDisposed) {
      return;
    }
    // Both copies, or the next throttle flush overwrites the flag with the
    // pre-stall snapshot it was holding.
    final pending = _pendingThrottledValue;
    if (pending != null) {
      _pendingThrottledValue = pending.copyWith(isStalled: true);
    }
    if (!value.isStalled) {
      value = value.copyWith(isStalled: true);
    }
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw StateError('The controller has been disposed.');
    }
  }

  /// Disposes the controller and releases the attached native player.
  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    final viewId = _viewId;
    _viewId = null;
    _textureId = null;
    _eventsSubscription?.cancel();
    _eventsSubscription = null;
    _cancelPendingThrottledValue();
    _cancelStallTimer();
    _clearPendingSeek();
    _dropMergedSeek();
    _pendingSeekTarget.dispose();
    if (viewId != null) {
      unawaited(_disposeNativeView(viewId));
    }
    super.dispose();
  }
}
