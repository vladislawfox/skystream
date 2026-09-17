import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/engine/js_engine.dart';
import 'package:skystream/core/network/apple_http_transport.dart';

// Native Cupertino symbols are linked by Xcode in the app. A macOS host test
// can preload the same module via SKYSTREAM_CUPERTINO_LIBRARY (see build notes).
void main() {
  final nativeLibrary = Platform.environment['SKYSTREAM_CUPERTINO_LIBRARY'];
  group('Apple HTTP transport', () {
    late HttpServer server;
    late Dio dio;
    late bool customDns;
    late _CustomDnsAdapter fallback;
    late String base;

    setUpAll(() => DynamicLibrary.open(nativeLibrary!));
    setUp(() async {
      customDns = false;
      fallback = _CustomDnsAdapter();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        switch (request.uri.path) {
          case '/redirect':
            request.response.statusCode = 302;
            request.response.headers.set('location', '/echo');
          case '/cookie':
            request.response.headers.add(
              'set-cookie',
              'session=private; Path=/',
            );
            request.response.write('set');
          case '/redirect-cookie':
            request.response.statusCode = 302;
            request.response.headers.set(
              'location',
              'http://localhost:${server.port}/cf-cookies',
            );
          case '/cf-cookies':
            request.response.headers.add(
              'set-cookie',
              'cf_clearance=one; Path=/; Expires=Wed, 09 Jun 2038 10:18:14 GMT',
            );
            request.response.headers.add('set-cookie', '__cf_bm=two; Path=/');
            request.response.write('cookies');
          case '/large':
            request.response.contentLength = 1000;
            request.response.add(List.filled(1000, 65));
          case '/slow':
            await Future<void>.delayed(const Duration(milliseconds: 200));
            request.response.write('late');
          default:
            request.response.write(
              jsonEncode({
                'method': request.method,
                'body': await utf8.decoder.bind(request).join(),
                'referer': request.headers.value('referer'),
                'cookie': request.headers.value('cookie'),
              }),
            );
        }
        try {
          await request.response.close();
        } catch (_) {}
      });
      dio = Dio(BaseOptions(responseType: ResponseType.plain))
        ..httpClientAdapter = AppleHttpClientAdapter(
          ioAdapter: fallback,
          useCustomDns: () => customDns,
        );
    });
    tearDown(() async {
      dio.close(force: true);
      await server.close(force: true);
    });

    test('preserves POST form bytes, Referer and redirects', () async {
      const body =
          'story=%D0%A0%D1%96%D0%BA+%2B+%D0%9C%D0%BE%D1%80%D1%82%D1%96';
      final response = await dio.post<String>(
        '$base/echo',
        data: body,
        options: Options(
          headers: {
            'Referer': 'https://provider.test',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        ),
      );
      final value = jsonDecode(response.data!) as Map;
      expect(value['body'], body);
      expect(value['method'], 'POST');
      expect(value['referer'], 'https://provider.test');
      expect((await dio.get<String>('$base/redirect')).statusCode, 200);
    });

    test('does not introduce an automatic shared session cookie jar', () async {
      await dio.get<String>('$base/cookie');
      final value =
          jsonDecode((await dio.get<String>('$base/echo')).data!) as Map;
      expect(value['cookie'], isNull);
    });

    test('reports the final URL to plugins after a redirect', () async {
      final response = await fetchCappedPlainBody(
        dio,
        '$base/redirect',
        options: Options(),
      );
      expect(response.realUri, Uri.parse('$base/echo'));
    });

    test(
      'retains separate CF cookies and scopes them to the final host',
      () async {
        final jar = CookieJar();
        dio.interceptors.add(CfOnlyCookieInterceptor(jar));
        final response = await dio.get<String>('$base/redirect-cookie');
        expect(response.headers['set-cookie'], hasLength(2));
        expect(await jar.loadForRequest(Uri.parse('$base/echo')), isEmpty);
        final cookies = await jar.loadForRequest(
          Uri.parse('http://localhost:${server.port}/echo'),
        );
        expect(
          {for (final cookie in cookies) cookie.name: cookie.value},
          {'cf_clearance': 'one', '__cf_bm': 'two'},
        );
      },
    );

    test(
      'retains the existing custom DNS adapter when toggled at runtime',
      () async {
        expect((await dio.get<String>('$base/echo')).statusCode, 200);
        expect(fallback.calls, 0);
        customDns = true;
        expect((await dio.get<String>('$base/echo')).data, 'custom-dns');
        expect(fallback.calls, 1);
        customDns = false;
        expect((await dio.get<String>('$base/echo')).data, contains('GET'));
      },
    );

    test('cancels in-flight native requests', () async {
      final token = CancelToken();
      final pending = dio.get<String>('$base/slow', cancelToken: token);
      final expectation = expectLater(
        pending,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      Timer(
        const Duration(milliseconds: 30),
        () => token.cancel('left screen'),
      );
      await expectation;
    });

    test('preserves the plugin response byte cap', () async {
      await expectLater(
        fetchCappedPlainBody(dio, '$base/large', options: Options(), limit: 16),
        throwsA(isA<JsHttpResponseTooLargeException>()),
      );
    });
  }, skip: !Platform.isMacOS || nativeLibrary == null);
}

class _CustomDnsAdapter implements HttpClientAdapter {
  var calls = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString('custom-dns', 200);
  }

  @override
  void close({bool force = false}) {}
}
