// Opt-in live test. Supply REZKA_SCRIPT (base64 of the built plugin.js) and
// REZKA_MANIFEST through --dart-define-from-file. No credentials are needed.
import 'dart:convert';

import 'package:skystream/core/domain/entity/multimedia_item.dart';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/extensions/engine/js_engine.dart';
import 'package:skystream/core/extensions/providers/js_based_provider.dart';
import 'package:skystream/core/network/apple_http_transport.dart';
import 'package:skystream/core/storage/extension_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';

class _Repo extends ExtensionRepository {
  _Repo() : super(StorageService());
  @override
  String? getExtensionData(String key) => null;
  @override
  Future<void> setExtensionData(String key, String? value) async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const encoded = String.fromEnvironment('REZKA_SCRIPT');
  testWidgets(
    'RezkaTV native browser, search, film and exact series episode',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('RezkaTV live verification')),
        ),
      );
      await tester.runAsync(() async {
        final dio = Dio()
          ..httpClientAdapter = AppleHttpClientAdapter(
            ioAdapter: IOHttpClientAdapter(),
            useCustomDns: () => false,
          );
        final engine = JsEngineService(_Repo(), dio);
        final manifest = jsonDecode(
          utf8.decode(
            base64Decode(const String.fromEnvironment('REZKA_MANIFEST')),
          ),
        ) as Map<String, dynamic>;
        final provider = JsBasedProvider(
          engine,
          'assets/rezka-live.js',
          namespace: 'RezkaLive',
          packageName: manifest['packageName'] as String,
          manifest: manifest,
          scriptLoader: () async => utf8.decode(base64Decode(encoded)),
        );
        try {
          final home = await provider.getHome();
          expect(home.keys, containsAll(['Фільми', 'Серіали', 'Мультфільми']));
          expect(home.values.every((items) => items.isNotEmpty), isTrue);
          final found = await provider.search('Стрела');
          final series = found.firstWhere((item) => item.url.contains('/153-'));
          final details = await provider.getDetails(series.url);
          final episode = details.episodes!.firstWhere(
            (e) => e.season == 1 && e.episode == 15,
          );
          final streams = await provider.loadStreams(episode.url);
          expect(streams, isNotEmpty);
          final hls = streams.firstWhere(
            (s) => Uri.parse(s.url).path.endsWith('.m3u8'),
          );
          final playlist = await readPlaylist(dio, hls);
          expect(playlist.statusCode, 200);
          expect(playlist.body.trimLeft(), startsWith('#EXTM3U'));
          expect(playlist.body, contains('#EXTINF:'));
          final duration = RegExp(r'#EXTINF:([\d.]+)')
              .allMatches(playlist.body)
              .fold<double>(0, (sum, m) => sum + double.parse(m[1]!));
          expect(
            duration,
            greaterThan(30 * 60),
            reason: 'Full episode playlist, not a preview',
          );
          debugPrint(
            'REZKA_LIVE series: ${details.episodes!.length} episodes, ${streams.length} streams for S1E15',
          );
          final movies = await provider.search('Форсаж');
          final movie = movies.firstWhere(
            (item) => item.url.contains('/films/') && item.title == 'Форсаж',
          );
          final movieDetails = await provider.getDetails(movie.url);
          expect(movieDetails.title, 'Форсаж');
          final movieStreams = await provider.loadStreams(movie.url);
          expect(movieStreams, isNotEmpty);
          final movieHls = movieStreams.firstWhere(
            (s) => Uri.parse(s.url).path.endsWith('.m3u8'),
          );
          final moviePlaylist = await readPlaylist(dio, movieHls);
          expect(moviePlaylist.statusCode, 200);
          expect(moviePlaylist.body.trimLeft(), startsWith('#EXTM3U'));
          final movieDuration = RegExp(r'#EXTINF:([\d.]+)')
              .allMatches(moviePlaylist.body)
              .fold<double>(0, (sum, m) => sum + double.parse(m[1]!));
          expect(
            movieDuration,
            greaterThan(80 * 60),
            reason: 'Full movie playlist, not a preview',
          );
          debugPrint(
            'REZKA_LIVE playlist durations: episode ${duration.round()}s, movie ${movieDuration.round()}s',
          );
          debugPrint(
            'REZKA_LIVE movie: ${movieStreams.length} streams; home/search/details successful',
          );
        } finally {
          engine.dispose();
          dio.close(force: true);
        }
      });
    },
    skip: encoded.isEmpty,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

Future<CappedHttpResponse> readPlaylist(Dio dio, StreamResult stream) async {
  for (var attempt = 0; ; attempt++) {
    final response = await fetchCappedPlainBody(
      dio,
      stream.url,
      options: Options(headers: stream.headers, validateStatus: (_) => true),
    );
    if (attempt >= 1 || ![502, 503, 504].contains(response.statusCode)) {
      return response;
    }
    debugPrint('REZKA_LIVE CDN ${response.statusCode}; one transient retry');
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}
