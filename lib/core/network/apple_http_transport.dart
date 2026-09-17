import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:native_dio_adapter/native_dio_adapter.dart';

import 'http_response_metadata.dart';

/// Use the system TLS/HTTP implementation on Apple platforms. Some providers
/// accept URLSession requests but challenge dart:io's HTTP client, even when
/// the URL and request headers are identical.
URLSessionConfiguration appleSessionConfiguration() =>
    URLSessionConfiguration.ephemeralSessionConfiguration()
      // The extension engine owns cookie policy; don't introduce an implicit
      // second jar shared by every provider through URLSession.
      ..httpShouldSetCookies = false
      ..timeoutIntervalForRequest = const Duration(seconds: 15)
      ..waitsForConnectivity = false;

/// A custom DoH resolver needs dart:io's socket factory. Choose per request so
/// toggling that existing setting still takes effect without restarting Dio.
class AppleHttpClientAdapter implements HttpClientAdapter {
  AppleHttpClientAdapter({
    required HttpClientAdapter ioAdapter,
    required bool Function() useCustomDns,
  }) : _ioAdapter = ioAdapter,
       _useCustomDns = useCustomDns;

  final HttpClientAdapter _ioAdapter;
  final bool Function() _useCustomDns;
  CupertinoClient? _nativeClient;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_useCustomDns()) {
      return _ioAdapter.fetch(options, requestStream, cancelFuture);
    }
    // Capture metadata per request: concurrent responses must never share it.
    // The upstream conversion layer drops the URL and combines Set-Cookie.
    final capture = _ResponseCaptureClient(
      _nativeClient ??= CupertinoClient.fromSessionConfiguration(
        appleSessionConfiguration(),
      ),
    );
    final body = await ConversionLayerAdapter(
      capture,
    ).fetch(options, requestStream, cancelFuture);
    final response = capture.response!;
    if (response case http.BaseResponseWithUrl(:final url)) {
      body.extra[nativeResponseUriKey] = url;
    }
    final cookies = response.headersSplitValues['set-cookie'];
    if (cookies != null) body.headers['set-cookie'] = cookies;
    return body;
  }

  @override
  void close({bool force = false}) {
    _nativeClient?.close();
    _ioAdapter.close(force: force);
  }
}

/// Borrows a shared session. Only AppleHttpClientAdapter owns its lifetime.
class _ResponseCaptureClient extends http.BaseClient {
  _ResponseCaptureClient(this.client);

  final http.Client client;
  http.StreamedResponse? response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response = await client.send(request);
}

/// CachedNetworkImage uses package:http separately from Dio. Give posters the
/// same native transport as details; keep the existing image cache limits.
void configureAppleImageCache() {
  CachedNetworkImageProvider.defaultCacheManager = CacheManager(
    Config(
      'skystreamAppleImages',
      fileService: HttpFileService(
        httpClient: CupertinoClient.fromSessionConfiguration(
          appleSessionConfiguration(),
        ),
      ),
    ),
  );
}
