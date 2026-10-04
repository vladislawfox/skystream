import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/link_probe_service.dart';

/// Answers each request from a table the test sets up, and records it.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.answer);

  final ResponseBody Function(RequestOptions options) answer;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return answer(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _html(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
  },
);

/// What the sources sheet's check makes of a link.
///
/// HubCloud's 10Gbps buttons answer 200 with a link generator - a web page
/// whose script sends a browser on to the file. The sheet called that a
/// working link, and the player then failed on it.
void main() {
  LinkProbeService serviceWith(_FakeAdapter adapter) =>
      LinkProbeService(Dio()..httpClientAdapter = adapter);

  test('a link that answers with a web page is not a video', () async {
    final adapter = _FakeAdapter(
      (_) => _html(
        '<!DOCTYPE html>\n<html><head><title>HubCloud - Link Generator'
        '</title></head><body></body></html>',
      ),
    );

    final result = await serviceWith(adapter)
        .probe('https://gpdl.hubcloud.test/?id=92d2');

    expect(result.reachable, isFalse);
    expect(result.failureReason, 'Not a video');
  });

  test('a playlist a script serves as a web page still works', () async {
    final adapter = _FakeAdapter(
      (_) => _html('#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:10,\nseg0.ts\n'),
    );

    final result = await serviceWith(adapter)
        .probe('https://cdn.test/live.php?id=7');

    expect(result.reachable, isTrue);
  });

  test('a video is taken at its word, without reading any of it', () async {
    final adapter = _FakeAdapter(
      (_) => ResponseBody.fromString(
        '',
        200,
        headers: {
          Headers.contentTypeHeader: ['video/mp4'],
        },
      ),
    );

    final result = await serviceWith(adapter).probe('https://cdn.test/a.mp4');

    expect(result.reachable, isTrue);
    expect(adapter.requests.map((r) => r.method), ['HEAD']);
  });

  // A server that refuses HEAD gets a ranged GET, and one that ignores the
  // range answers it with the whole file. Read as bytes, that was the whole
  // file - 18 GB for the film this was found on - buffered in memory.
  test(
    'a file whose server ignores the range is not read past its start',
    () async {
      var sent = 0;
      final adapter = _FakeAdapter((options) {
        if (options.method == 'HEAD') {
          return ResponseBody.fromString('', 405);
        }
        final endless = Stream<Uint8List>.periodic(Duration.zero, (_) {
          sent++;
          return Uint8List.fromList(utf8.encode('x' * 4096));
        });
        return ResponseBody(
          endless,
          200,
          headers: {
            Headers.contentTypeHeader: ['video/x-matroska'],
          },
        );
      });

      final result = await serviceWith(adapter)
          .probe('https://video-downloads.test/file')
          .timeout(const Duration(seconds: 5));

      expect(result.reachable, isTrue);
      expect(sent, lessThan(64), reason: 'it stopped reading at the start');
    },
  );
}
