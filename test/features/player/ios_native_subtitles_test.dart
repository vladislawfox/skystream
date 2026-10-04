import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart';
import 'package:skystream/features/player/presentation/vlc/side_car_subtitle_view.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

// AVKit presents VLC frames only. A Flutter subtitle overlay cannot travel
// with the sample-buffer layer when the app enters PiP.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const iosPip = MethodChannel('vlc_player/pip');
  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        engine.dispose();
        engine = FakeVlcEngine(viewId: (call.arguments as Map)['id'] as int);
        engine.install();
      }
      return null;
    });
    messenger.setMockMethodCallHandler(iosPip, (_) async => null);
  });

  tearDown(() {
    engine.dispose();
    removeEngineMocks();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    messenger.setMockMethodCallHandler(iosPip, null);
  });

  Future<void> open(WidgetTester tester, SubtitleDefault mode) async {
    await pumpPlayer(
      tester,
      settings: PlayerSettings(subtitleDefault: mode),
      preloadedStreams: [
        StreamResult(
          url: '/movies/episode.mp4',
          source: '1080p',
          subtitles: [
            SubtitleFile(
              url: '/subs/english.srt',
              label: 'English',
              lang: 'en',
            ),
          ],
        ),
      ],
    );
    await engine.emit();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('iOS registers external subtitles in VLC across PiP', (
    tester,
  ) async {
    await open(tester, SubtitleDefault.auto);
    expect(engine.callsTo('addSubtitle'), hasLength(1));
    expect(engine.activeSubtitleId, greaterThanOrEqualTo(0));
    expect(find.byType(SideCarSubtitleView), findsNothing);
    final selected = engine.activeSubtitleId;
    for (final active in [true, false]) {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        iosPip.name,
        iosPip.codec.encodeMethodCall(MethodCall('pipModeChanged', active)),
        (_) {},
      );
      await engine.emit();
      await tester.pump(const Duration(milliseconds: 400));
      expect(engine.activeSubtitleId, selected);
    }
    expect(engine.callsTo('disableSubtitle'), isEmpty);
    await tester.tap(find.byTooltip('Subtitles'));
    await settle(tester);
    expect(
      tester.widget<PlayerPanel>(find.byType(PlayerPanel)).sideCars,
      isNull,
      reason: 'file-picker and search subtitles must also go to VLC',
    );
    await tester.pumpWidget(const SizedBox());
  }, variant: ios);

  testWidgets('iOS Off retains native subtitle choices without enabling them', (
    tester,
  ) async {
    await open(tester, SubtitleDefault.off);
    expect(engine.callsTo('addSubtitle'), hasLength(1));
    expect(engine.subtitle, isNotEmpty);
    expect(engine.activeSubtitleId, -1);
    await tester.pumpWidget(const SizedBox());
  }, variant: ios);
}
