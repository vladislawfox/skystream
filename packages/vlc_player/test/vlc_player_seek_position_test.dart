import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'vlc_method_channel_harness.dart';

/// [VlcPlayerController.pendingSeekTarget]: where a seek is going while the
/// engine still reports where it was.
///
/// libVLC answers a seek with the position it left for as long as the stream
/// takes to reach the new one - seconds, on a network file - so a scrubber
/// drawn from the position alone sprang back to where the viewer was and
/// jumped forward when the buffer filled. Media3 and the browsers report the
/// target from the moment a seek is asked for. The controller keeps the
/// engine's own position as it is - resume points and relative steps must
/// only ever see places playback reached - and publishes the target beside
/// it for the scrubber and the clock.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VlcMethodChannelHarness harness;

  setUp(() {
    harness = VlcMethodChannelHarness()..install();
  });

  tearDown(() {
    harness.dispose();
  });

  Map<String, Object?> snapshot({
    String state = 'playing',
    required int position,
  }) {
    return <String, Object?>{
      'state': state,
      'position': position,
      'duration': 3600000,
      'isReady': true,
    };
  }

  /// An attached controller playing at 10:00.
  Future<VlcPlayerController> playing(int viewId) async {
    final controller = VlcPlayerController();
    harness.mockEventChannel(viewId);
    await harness.attachController(controller, viewId);
    await harness.sendEvent(viewId, snapshot(position: 600000));
    return controller;
  }

  Duration ms(int value) => Duration(milliseconds: value);

  testWidgets('the target is published the moment the seek is asked for, and '
      'the position stays the engine\'s', (tester) async {
    final controller = await playing(1);
    final seen = <Duration?>[];
    controller.pendingSeekTarget.addListener(
      () => seen.add(controller.pendingSeekTarget.value),
    );

    await controller.seekTo(const Duration(minutes: 30));

    expect(seen, <Duration?>[const Duration(minutes: 30)]);
    expect(controller.value.position, ms(600000));
    // The stall clock and the merge window are both armed by the seek; ending
    // healthy means disposing in-body, before flutter_test checks for pending
    // timers.
    controller.dispose();
  });

  testWidgets('it holds while the engine still reports where it was, and '
      'goes when the engine arrives', (tester) async {
    final controller = await playing(2);

    await controller.seekTo(const Duration(minutes: 30));
    // Refilling at the new place: the engine repeats the old position.
    await harness.sendEvent(2, snapshot(state: 'buffering', position: 600000));
    await harness.sendEvent(2, snapshot(state: 'buffering', position: 600000));
    await tester.pump(const Duration(seconds: 10));
    expect(controller.pendingSeekTarget.value, const Duration(minutes: 30));

    await harness.sendEvent(2, snapshot(position: 1800040));
    expect(controller.pendingSeekTarget.value, isNull);
    expect(controller.value.position, ms(1800040));
    controller.dispose();
  });

  testWidgets('a landing a little short of the target counts', (tester) async {
    // A keyframe or an HLS segment boundary before the millisecond asked for.
    final controller = await playing(3);

    await controller.seekTo(const Duration(minutes: 30));
    await harness.sendEvent(3, snapshot(position: 1797600));

    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('backwards too, and past the target in the seek\'s direction', (
    tester,
  ) async {
    final controller = await playing(4);

    await controller.seekTo(const Duration(minutes: 5));
    // A report from the old place, a little on.
    await harness.sendEvent(4, snapshot(position: 600500));
    expect(controller.pendingSeekTarget.value, const Duration(minutes: 5));

    // A keyframe well before the target is still the seek landing.
    await harness.sendEvent(4, snapshot(position: 290000));
    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('a chain of steps is not undone by an earlier step landing', (
    tester,
  ) async {
    // Three presses of a D-pad's Right before the first has landed.
    final controller = await playing(5);

    await controller.seekTo(ms(610000));
    await controller.seekTo(ms(620000));
    await controller.seekTo(ms(630000));
    expect(controller.pendingSeekTarget.value, ms(630000));

    await harness.sendEvent(5, snapshot(position: 610000));
    await harness.sendEvent(5, snapshot(position: 620000));
    expect(controller.pendingSeekTarget.value, ms(630000));

    await harness.sendEvent(5, snapshot(position: 630020));
    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('a short step cannot be landed by the report it left from', (
    tester,
  ) async {
    final controller = await playing(6);

    await controller.seekTo(ms(602000));
    await harness.sendEvent(6, snapshot(position: 600250));

    expect(controller.pendingSeekTarget.value, ms(602000));
    controller.dispose();
  });

  testWidgets('a paused seek holds its target too', (tester) async {
    final controller = await playing(7);
    await harness.sendEvent(7, snapshot(state: 'paused', position: 600000));

    await controller.seekTo(const Duration(minutes: 20));
    await harness.sendEvent(7, snapshot(state: 'paused', position: 600000));

    expect(controller.pendingSeekTarget.value, const Duration(minutes: 20));
    // A seek leaves its merge window open; see the first test.
    controller.dispose();
  });

  testWidgets('an engine that stops, ends or fails lets the target go', (
    tester,
  ) async {
    final controller = await playing(8);

    await controller.seekTo(const Duration(minutes: 30));
    await harness.sendEvent(8, snapshot(state: 'ended', position: 3600000));

    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('new media drops the old media\'s target', (tester) async {
    final controller = await playing(9);
    addTearDown(controller.dispose);

    await controller.seekTo(const Duration(minutes: 30));
    await controller.setMedia(
      VlcMediaSource(uri: Uri.parse('https://example.com/next.mkv')),
    );

    expect(controller.pendingSeekTarget.value, isNull);
  });

  testWidgets('playback carrying on elsewhere is a seek that did not happen', (
    tester,
  ) async {
    // An engine that took the call and ignored it: the clock runs on from
    // where it was, and the scrubber must follow it rather than sit on a
    // target twenty minutes away until playback gets there.
    final controller = await playing(10);

    await controller.seekTo(const Duration(minutes: 30));
    var position = 600000;
    for (var tick = 0; tick < 11; tick++) {
      position += 250;
      await harness.sendEvent(10, snapshot(position: position));
    }
    expect(controller.pendingSeekTarget.value, const Duration(minutes: 30));

    await harness.sendEvent(10, snapshot(position: position + 250));
    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });
}
