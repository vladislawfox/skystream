import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'test_support.dart';

const String _assetRoot = 'assets/format_fixtures';

/// How long the fixture's segment hangs before giving up. Longer than any
/// sane answer to "does leaving this stream freeze the app", and short enough
/// that a run against a build that does freeze still ends.
const Duration _stall = Duration(seconds: 12);

/// Leaving a live stream whose download has stalled must not freeze the app.
///
/// libVLC 3 tears a player's stream down synchronously: `stop()` and
/// `set_media()` both stop the input thread and wait for it to exit, and they
/// hold the player's input lock while they do. A live HLS stream whose segment
/// read has stalled keeps that thread alive for as long as the read lasts.
/// The plugin made both calls on the Android main thread - which Flutter's UI
/// thread is merged into - so pressing back, or switching to another source,
/// held the whole app for as long as the download did. Past five seconds
/// Android reports the app as not responding; users saw it freeze and die.
///
/// The server runs on its own isolate: a frozen main thread would otherwise
/// freeze it too, and the stalled read would never end.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('switching away from a stalled live stream is immediate', (
    tester,
  ) async {
    final server = await _StallingHlsServer.start();
    addTearDown(server.close);
    final controller = await _playStalledStream(tester, server);

    final clock = Stopwatch()..start();
    await controller.setMedia(
      VlcMediaSource(uri: await materializeAsset('$_assetRoot/video.mp4')),
      autoPlay: true,
    );
    clock.stop();

    expect(
      clock.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'switching source waited on the stalled stream',
    );
    // And the source it switched to really plays, picture and all.
    await pumpUntil(
      tester,
      () => controller.value.displayVideoSize != null,
      description: 'the new source playing',
    );
    expect(controller.value.hasError, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('leaving the player during a stalled live stream is immediate', (
    tester,
  ) async {
    final server = await _StallingHlsServer.start();
    addTearDown(server.close);
    final controller = await _playStalledStream(tester, server);

    final clock = Stopwatch()..start();
    // What pressing back does: the player's widget goes, which disposes the
    // platform view, and the owner disposes the controller.
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    // A round trip through the event loop only completes once the main
    // thread is free again.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    clock.stop();

    expect(
      clock.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'leaving the player waited on the stalled stream',
    );
  });
}

/// Mounts a player with the app's network options and has it open the stalled
/// live stream, then waits until libVLC is inside the download that hangs.
Future<VlcPlayerController> _playStalledStream(
  WidgetTester tester,
  _StallingHlsServer server,
) async {
  final controller = VlcPlayerController(
    options: <String>[
      ...headlessPlayerOptions(),
      // What SkyStream runs with: see VlcNetworkConfig in the app.
      '--network-caching=3000',
      '--stream-filter=prefetch',
      '--prefetch-buffer-size=65536',
    ],
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 240,
          height: 135,
          child: VlcPlayer(controller: controller),
        ),
      ),
    ),
  );
  await pumpUntil(
    tester,
    () => controller.isAttached,
    description: 'native player attachment',
  );
  await controller.setMedia(
    VlcMediaSource(uri: server.playlistUri),
    autoPlay: true,
  );
  await pumpUntil(
    tester,
    () => server.segmentRequests > 0,
    description: 'libVLC asking for the segment that stalls',
  );
  // Give the download a moment to be well and truly stuck.
  await tester.pump(const Duration(seconds: 2));
  return controller;
}

/// A live HLS stream whose segments start downloading and then stop.
class _StallingHlsServer {
  _StallingHlsServer._(this._isolate, this.port, this._requests);

  final Isolate _isolate;
  final int port;
  final ReceivePort _requests;
  int segmentRequests = 0;

  Uri get playlistUri => Uri.parse('http://127.0.0.1:$port/live.m3u8');

  static Future<_StallingHlsServer> start() async {
    final ready = ReceivePort();
    final requests = ReceivePort();
    final isolate = await Isolate.spawn(_serve, <Object>[
      ready.sendPort,
      requests.sendPort,
      _stall.inMilliseconds,
    ]);
    final port = await ready.first as int;
    final server = _StallingHlsServer._(isolate, port, requests);
    requests.listen((_) => server.segmentRequests += 1);
    return server;
  }

  void close() {
    _requests.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

Future<void> _serve(List<Object> args) async {
  final ready = args[0] as SendPort;
  final requests = args[1] as SendPort;
  final stall = Duration(milliseconds: args[2] as int);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  ready.send(server.port);

  var sequence = 0;
  await for (final request in server) {
    if (request.uri.path.endsWith('.m3u8')) {
      // Live: no end tag, so the playlist is fetched again as it goes.
      request.response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
      );
      request.response.write(
        '#EXTM3U\n'
        '#EXT-X-VERSION:3\n'
        '#EXT-X-TARGETDURATION:4\n'
        '#EXT-X-MEDIA-SEQUENCE:$sequence\n'
        '#EXTINF:4.0,\nseg$sequence.ts\n'
        '#EXTINF:4.0,\nseg${sequence + 1}.ts\n',
      );
      sequence += 1;
      await request.response.close();
      continue;
    }
    requests.send(request.uri.path);
    // A segment that starts and then goes quiet: headers and a first packet,
    // then nothing until the stall runs out.
    unawaited(() async {
      try {
        request.response.headers.contentType = ContentType('video', 'mp2t');
        request.response.contentLength = 4 * 1024 * 1024;
        request.response.add(List<int>.filled(188, 0)..[0] = 0x47);
        await request.response.flush();
        await Future<void>.delayed(stall);
        await request.response.close();
      } catch (_) {
        // The client went away first, which is the point.
      }
    }());
  }
}
