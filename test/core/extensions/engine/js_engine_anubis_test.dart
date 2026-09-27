import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/engine/js_engine.dart';
import 'package:skystream/core/network/cloudflare_bypass.dart';
import 'package:skystream/core/storage/extension_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';

const challenge =
    '<html><script id="anubis_challenge" type="application/json">{}</script></html>';

class _Repo extends ExtensionRepository {
  _Repo() : super(StorageService());
}

class _Adapter implements HttpClientAdapter {
  _Adapter({this.responseHeaders = const {}});
  final Map<String, List<String>> responseHeaders;
  final requests = <RequestOptions>[];
  bool alwaysBlocked = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      requests.length == 1 || alwaysBlocked
          ? challenge
          : '{"success":true,"url":"video"}',
      200,
      headers: responseHeaders,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'response persistence includes Anubis clearance but excludes login cookies',
    () async {
      final jar = CookieJar();
      final dio = Dio()
        ..httpClientAdapter = _Adapter(
          responseHeaders: {
            'set-cookie': [
              'techaro.lol-anubis-auth=clearance; Secure; HttpOnly; Path=/',
              'session=private; Secure; Path=/',
            ],
          },
        );
      dio.interceptors.add(CfOnlyCookieInterceptor(jar));
      await dio.get<void>('https://rezka.test/');
      expect(
        (await jar.loadForRequest(Uri.parse('https://rezka.test/')))
            .map((c) => c.name),
        ['techaro.lol-anubis-auth'],
      );
      dio.close();
    },
  );
  test(
    'one cancelled request does not abort another waiting on the same solve',
    () async {
      final done = Completer<CfResult?>();
      final cancelA = Completer<void>();
      final cancelB = Completer<void>();
      final session = AnubisSession()..result = done.future;
      final a = session.join(cancelA.future);
      final b = session.join(cancelB.future);
      cancelA.complete();
      expect(await a, isNull);
      expect(session.cancelled, isFalse);
      cancelB.complete();
      expect(await b, isNull);
      expect(session.cancelled, isTrue);
      done.complete(null);
    },
  );
  test(
    'a shared solve returns the same result to its active waiters',
    () async {
      final done = Completer<CfResult?>();
      final session = AnubisSession()..result = done.future;
      final a = session.join(null);
      final b = session.join(null);
      const result = CfResult(
        body: 'ok',
        statusCode: 200,
        finalUrl: 'https://test/',
      );
      done.complete(result);
      expect(await a, same(result));
      expect(await b, same(result));
    },
  );
  test('Anubis detection requires a challenge script, not an article mentioning Anubis', () {
    expect(CloudflareBypass.isAnubisChallenge(challenge), isTrue);
    expect(
      CloudflareBypass.isAnubisChallenge(
        "<script type='application/json' id='anubis_challenge'>null</script>",
      ),
      isTrue,
    );
    expect(
      CloudflareBypass.isAnubisChallenge('<p>Anubis anubis_challenge</p>'),
      isFalse,
    );
  });

  for (final scenario in ['GET', 'POST', 'still-blocked', 'solve-failed']) {
    final method = scenario == 'GET' ? 'GET' : 'POST';
    test('Anubis $scenario preserves request and bounds retries', () async {
      final port = ReceivePort();
      final reply = Completer<Map<dynamic, dynamic>>();
      port.listen((dynamic message) {
        if (message is Map && message['rv'] != null) {
          reply.complete(message['rv'] as Map<dynamic, dynamic>);
        }
      });
      final adapter = _Adapter()..alwaysBlocked = scenario == 'still-blocked';
      final dio = Dio()..httpClientAdapter = adapter;
      final engine = JsEngineService.withWorkerPort(
        _Repo(),
        dio,
        port.sendPort,
      );
      addTearDown(() {
        engine.dispose();
        port.close();
      });
      final token = engine.mintBridgeToken(
        namespace: 'rezka',
        packageName: 'com.test.rezka',
      );
      var solves = 0;
      engine.solveAnubis =
          (url, {required userAgent, cancellation, callerId, onSolved}) async {
            solves++;
            expect(url, 'https://rezka.test/');
            expect(userAgent, 'test-browser');
            expect(callerId, 'rezka');
            if (scenario == 'solve-failed') return null;
            return const CfResult(
              body: '<html>Catalog</html>',
              statusCode: 200,
              finalUrl: 'https://rezka.test/',
            );
          };
      engine.handleWorkerMessage({
        'bg': 1,
        'bid': 1,
        'ch': 'http_request',
        'aj': jsonEncode({
          'id': 'request',
          '__ssTok': token,
          'method': method,
          'url': 'https://rezka.test/ajax/get_cdn_series/',
          'headers': {
            'User-Agent': 'test-browser',
            'Referer': 'https://rezka.test/series/42.html',
          },
          'body': method == 'POST'
              ? 'id=42&season=1&episode=15&action=get_stream'
              : null,
        }),
      });
      final result = await reply.future.timeout(const Duration(seconds: 5));
      expect(
        result['body'],
        scenario == 'still-blocked' || scenario == 'solve-failed'
            ? challenge
            : '{"success":true,"url":"video"}',
      );
      expect(solves, 1);
      expect(adapter.requests, hasLength(scenario == 'solve-failed' ? 1 : 2));
      expect(adapter.requests.last.method, method);
      expect(adapter.requests.last.data, adapter.requests.first.data);
      expect(adapter.requests.last.uri, adapter.requests.first.uri);
      expect(adapter.requests.last.headers['User-Agent'], 'test-browser');
    });
  }

  test('cookie interceptor stores only approved clearance cookies and respects host scope', () async {
    final jar = CookieJar();
    final adapter = _Adapter();
    final dio = Dio()..httpClientAdapter = adapter;
    dio.interceptors.add(CfOnlyCookieInterceptor(jar));
    await jar.saveFromResponse(Uri.parse('https://rezka.test/'), [
      Cookie('techaro.lol-anubis-auth', 'clearance')..secure = true,
      Cookie('session', 'private-login')..secure = true,
    ]);
    await dio.get<void>('https://rezka.test/');
    expect(
      adapter.requests.last.headers['Cookie'],
      'techaro.lol-anubis-auth=clearance',
    );
    await dio.get<void>('https://other.test/');
    expect(adapter.requests.last.headers['Cookie'], isNull);
  });
}
