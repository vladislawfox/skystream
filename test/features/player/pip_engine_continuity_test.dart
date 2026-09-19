import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_screen.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/features/tracking/data/sync_manager.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

/// Entering picture-in-picture must not restart the film.
///
/// It used to. The playing stage had a second build branch returning a bare
/// `VlcPlayer` for PiP, so the widget occupying that slot changed the moment
/// the window shrank: Flutter rebuilt the element, `VlcPlayer.dispose`
/// detached, the native player died, and the controller re-opened its media
/// from the position it was originally opened at. Fifty minutes into an
/// episode, PiP put the viewer back at the beginning.
///
/// The only honest proof is element identity - that the *same* `VlcPlayer`
/// State object is still there afterwards, because that is what owns the
/// attachment to the engine. Asserting that the video "is still on screen"
/// would pass against the broken build too.
///
/// The subject is playback that is actually running, which means the engine
/// has to be reachable from the test: until the first frame lands the screen
/// covers the video with its opening overlay and there is no chrome to hide.
/// The test records both texture creation and platform-view creation so it
/// can send decoded-frame events to the same native player channel on iOS.
const MethodChannel _pip = MethodChannel('dev.akash.skystream.player/pip');
const MethodChannel _iosPip = MethodChannel('vlc_player/pip');
const MethodChannel _vlc = MethodChannel('vlc_player');

const int _viewId = 1;
int _activeViewId = _viewId;
EventChannel get _events => EventChannel('vlc_player/events/$_activeViewId');

final TargetPlatformVariant _texturePlatform = TargetPlatformVariant.only(
  TargetPlatform.windows,
);

/// The wakelock is taken and released from unawaited futures, so it has to be
/// answered or the failure surfaces as a stray PlatformException attributed to
/// whichever test happened to be running. wakelock_plus speaks pigeon rather
/// than a MethodChannel, hence the raw channel name.
const String _wakelockToggle =
    'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

/// Pigeon reads a reply of `[value]` as success and anything else - a null
/// envelope included - as a dead channel.
final ByteData? _wakelockReply = const StandardMessageCodec().encodeMessage(
  <Object?>[null],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final engineCalls = <MethodCall>[];
  final eventChannels = <EventChannel>[];
  final createdViews = <int>[];

  void registerEvents(int viewId) {
    _activeViewId = viewId;
    final channel = _events;
    eventChannels.add(channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          channel,
          MockStreamHandler.inline(onListen: (arguments, sink) {}),
        );
  }

  setUp(() {
    engineCalls.clear();
    createdViews.clear();
    _activeViewId = _viewId;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // The engine and the platform view host answer with nothing. Unmocked
    // they throw MissingPluginException from an unawaited future, which lands
    // on the test rather than on the call site.
    messenger.setMockMethodCallHandler(_vlc, (call) async {
      engineCalls.add(call);
      if (call.method == 'create') {
        return <String, Object?>{'viewId': _viewId, 'textureId': _viewId};
      }
      return null;
    });
    registerEvents(_viewId);
    messenger.setMockMessageHandler(
      _wakelockToggle,
      (message) async => _wakelockReply,
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final id = (call.arguments as Map)['id'] as int;
        createdViews.add(id);
        registerEvents(id);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
      _iosPip,
      (call) async => call.method == 'enterPip' ? false : null,
    );
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_vlc, null);
    for (final channel in eventChannels) {
      messenger.setMockStreamHandler(channel, null);
    }
    eventChannels.clear();
    messenger.setMockMessageHandler(_wakelockToggle, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    // The screen registers this one itself; leaving it set outlives the State.
    messenger.setMockMethodCallHandler(_pip, null);
    messenger.setMockMethodCallHandler(_iosPip, null);
  });

  /// Tells the screen the activity has entered or left PiP, over the same
  /// channel `MainActivity.onPictureInPictureModeChanged` uses.
  Future<void> setPipMode(
    WidgetTester tester,
    bool inPip, {
    MethodChannel channel = _pip,
  }) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('pipModeChanged', inPip)),
      (_) {},
    );
    await tester.pump();
  }

  /// The engine reports a position that has moved, which is the only thing the
  /// screen accepts as proof that a frame exists - and therefore the only way
  /// past the opening overlay to the chrome this test is about.
  Future<void> sendFirstFrame(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _events.name,
      _events.codec.encodeSuccessEnvelope(<String, Object?>{
        'state': 'playing',
        'position': 1500,
        'duration': 0,
        'volume': 100,
        'playbackSpeed': 1.0,
        'isReady': true,
        'isSeekable': true,
        'isLive': false,
      }),
      null,
    );
    // Past the controller's 250ms event throttle.
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// An item from the `Remote` provider is the shortest honest route to the
  /// playing stage: `resolvePlayback` short-circuits to a direct stream, so
  /// the screen gets there with no plugin behind it. The resume lookup is the
  /// only other thing that would reach storage, and [_NoHistory] answers it.
  Future<void> pumpPlayingScreen(
    WidgetTester tester, {
    DeviceProfile profile = const DeviceProfile(isTv: true),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProfileProvider.overrideWithValue(AsyncValue.data(profile)),
          playerSettingsProvider.overrideWithBuild(
            (_, _) => const PlayerSettings(),
          ),
          historyRepositoryProvider.overrideWithValue(_NoHistory()),
          syncedProgressProvider.overrideWith((ref) async => []),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: VlcPlayerScreen(
            item: MultimediaItem(
              title: 'Channel One',
              url: 'https://example.com/live.m3u8',
              posterUrl: '',
              provider: 'Remote',
            ),
            videoUrl: 'https://example.com/live.m3u8',
          ),
        ),
      ),
    );
    // Resolution, the resume lookup, setMedia and the texture attach are all
    // async gaps. Pumped rather than settled: the opening overlay's spinner
    // runs until there is a frame, so there is no quiet frame to settle on.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      find.byType(VlcPlayer),
      findsOneWidget,
      reason: 'the screen never reached the playing stage',
    );
    await sendFirstFrame(tester);
  }

  testWidgets(
    'entering PiP keeps the engine attached',
    variant: _texturePlatform,
    (tester) async {
      await pumpPlayingScreen(tester);
      final player = tester.state(find.byType(VlcPlayer));
      expect(find.byType(VlcPlayerControls), findsOneWidget);

      await setPipMode(tester, true);

      expect(
        tester.state(find.byType(VlcPlayer)),
        same(player),
        reason: 'PiP rebuilt the video element, which kills the native player',
      );
      expect(
        find.byType(VlcPlayerControls),
        findsNothing,
        reason: 'at PiP size the chrome is an unreadable smear over the frame',
      );

      await setPipMode(tester, false);

      expect(tester.state(find.byType(VlcPlayer)), same(player));
      expect(find.byType(VlcPlayerControls), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final isTablet in [false, true]) {
    testWidgets(
      'iOS ${isTablet ? 'tablet' : 'phone'} offers manual PiP',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        await pumpPlayingScreen(
          tester,
          profile: DeviceProfile(isTablet: isTablet),
        );
        final controls = tester.widget<VlcPlayerControls>(
          find.byType(VlcPlayerControls),
        );
        expect(controls.onEnterPip, isNotNull);
        final pipCalls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          _iosPip,
          (call) async {
            pipCalls.add(call);
            return false;
          },
        );
        final pipButton = find.byIcon(Icons.picture_in_picture_alt_rounded);
        expect(pipButton, findsOneWidget);
        await tester.tap(pipButton);
        // The control strip's double-tap recognizer holds the gesture arena.
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
        expect(pipCalls, hasLength(1));
        expect(pipCalls.single.method, 'enterPip');
        expect(
          find.byType(VlcPlayerControls),
          findsOneWidget,
          reason: 'a rejected entry restores the controls',
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'iOS selects the inline sample-buffer view',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      await pumpPlayingScreen(tester, profile: const DeviceProfile());
      final widget = tester.widget<VlcPlayer>(find.byType(VlcPlayer));
      expect(widget.darwinRenderer, VlcDarwinRenderer.sampleBuffer);
      expect(find.byType(UiKitView), findsOneWidget);
      expect(
        widget.controller.backgroundPolicy,
        VlcBackgroundPolicy.keepPlaying,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'iOS PiP survives foregrounding without replacing or pausing the engine',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpPlayingScreen(tester, profile: const DeviceProfile());
      final player = tester.state(find.byType(VlcPlayer));
      final controller = tester
          .widget<VlcPlayer>(find.byType(VlcPlayer))
          .controller;
      final source = controller.currentMediaSource;
      engineCalls.clear();
      await setPipMode(tester, true, channel: _iosPip);
      expect(find.byType(VlcPlayerControls), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
        find.byType(VlcPlayerControls),
        findsNothing,
        reason: 'only the native PiP delegate can confirm it stopped',
      );
      await setPipMode(tester, false, channel: _iosPip);
      expect(find.byType(VlcPlayerControls), findsOneWidget);
      expect(tester.state(find.byType(VlcPlayer)), same(player));
      expect(controller.currentMediaSource, same(source));
      expect(controller.isAttached, isTrue);
      expect(createdViews, hasLength(1));
      expect(
        engineCalls.map((call) => call.method),
        isNot(
          anyOf(
            contains('pause'),
            contains('play'),
            contains('create'),
            contains('dispose'),
            contains('setMedia'),
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}

/// The resume lookup reads history, which ends in Hive. A test about element
/// identity has no business standing a storage stack up, so it reads empty.
class _NoHistory extends HistoryRepository {
  _NoHistory() : super(StorageService());

  @override
  List<HistoryItem> getWatchHistory() => const <HistoryItem>[];

  @override
  int getPosition(String url) => 0;

  @override
  int getDuration(String url) => 0;

  @override
  Future<void> saveProgress(
    MultimediaItem item,
    int position,
    int duration, {
    String? lastStreamUrl,
    String? lastEpisodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodePosterUrl,
  }) async {}
}
