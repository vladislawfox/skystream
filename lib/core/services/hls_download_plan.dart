import 'dart:convert';

import 'package:dio/dio.dart';

import '../network/http_response_metadata.dart';

/// A finite HLS presentation. All playlist references are local filenames;
/// only [assets] are fetched by the native background downloader.
class HlsDownloadPlan {
  final Map<String, String> playlists;
  final List<HlsDownloadAsset> assets;

  HlsDownloadPlan(this.playlists, this.assets);

  static bool matches(String url, String? mimeType) =>
      Uri.tryParse(url)?.path.toLowerCase().endsWith('.m3u8') == true ||
      (mimeType?.toLowerCase().contains('mpegurl') ?? false);

  static Future<HlsDownloadPlan> load(
    Dio dio,
    String url, {
    Map<String, String>? headers,
  }) {
    final effectiveHeaders = <String, String>{
      for (final entry in dio.options.headers.entries)
        entry.key: entry.value.toString(),
    };
    for (final entry in (headers ?? <String, String>{}).entries) {
      effectiveHeaders.removeWhere(
        (key, _) => key.toLowerCase() == entry.key.toLowerCase(),
      );
      effectiveHeaders[entry.key] = entry.value;
    }
    return _HlsPlanner(dio, effectiveHeaders).load(url);
  }

  Map<String, dynamic> toJson() => {
    'playlists': playlists,
    'assets': assets.map((asset) => asset.toJson()).toList(),
  };

  factory HlsDownloadPlan.fromJson(Map<String, dynamic> json) =>
      HlsDownloadPlan(
        Map<String, String>.from(json['playlists'] as Map),
        (json['assets'] as List)
            .map(
              (asset) => HlsDownloadAsset.fromJson(
                Map<String, dynamic>.from(asset as Map),
              ),
            )
            .toList(),
      );
}

class HlsDownloadAsset {
  final String url;
  final String filename;
  final Map<String, String> headers;
  final int? length;

  HlsDownloadAsset(this.url, this.filename, this.headers, this.length);

  Map<String, dynamic> toJson() => {
    'url': url,
    'filename': filename,
    'headers': headers,
    'length': length,
  };

  factory HlsDownloadAsset.fromJson(Map<String, dynamic> json) =>
      HlsDownloadAsset(
        json['url'] as String,
        json['filename'] as String,
        Map<String, String>.from(json['headers'] as Map),
        json['length'] as int?,
      );
}

class _HlsPlanner {
  final Dio dio;
  final Map<String, String> headers;
  final playlists = <String, String>{};
  final assets = <HlsDownloadAsset>[];
  final _assetNames = <String, String>{};
  final _visiting = <String>{};
  _HlsPlanner(this.dio, this.headers);

  Future<HlsDownloadPlan> load(String url) async {
    await _playlist(Uri.parse(url), 'index.m3u8', 0);
    if (assets.isEmpty) {
      throw const FormatException('HLS source has no media segments.');
    }
    return HlsDownloadPlan(playlists, assets);
  }

  Future<void> _playlist(Uri uri, String filename, int depth) async {
    final requestedUri = uri;
    if (depth > 4 || !_visiting.add(uri.toString())) {
      throw const FormatException('Invalid recursive HLS playlist.');
    }
    final response = await dio.get<ResponseBody>(
      uri.toString(),
      options: Options(
        headers: headers,
        responseType: ResponseType.stream,
        followRedirects: true,
      ),
    );
    final bytes = <int>[];
    await for (final chunk in response.data!.stream) {
      bytes.addAll(chunk);
      if (bytes.length > 2 * 1024 * 1024) {
        throw const FormatException('HLS playlist is too large.');
      }
    }
    final nativeFinalUri = response.extra[nativeResponseUriKey] as Uri?;
    if (nativeFinalUri != null) {
      uri = effectiveResponseUri(response);
    } else {
      // Dio's IO adapter may expose a relative final Location. Resolve each
      // hop against the preceding request, while URLSession uses its final URI.
      for (final redirect in response.redirects) {
        uri = uri.resolveUri(redirect.location);
      }
    }
    final text = utf8.decode(bytes).trim();
    if (!text.startsWith('#EXTM3U')) {
      throw const FormatException('Source is not an HLS playlist.');
    }
    final lines = const LineSplitter()
        .convert(text)
        .map((line) => line.trim())
        .toList();
    if (lines.any((line) => line.startsWith('#EXT-X-SESSION-KEY:'))) {
      throw const FormatException(
        'This encrypted HLS source cannot be downloaded.',
      );
    }
    final variants = <({int index, int bandwidth})>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF:')) {
        variants.add((
          index: i,
          bandwidth: int.tryParse(_attrs(lines[i])['BANDWIDTH'] ?? '') ?? 0,
        ));
      }
    }
    if (variants.isNotEmpty) {
      variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
      final selected = variants.first.index;
      final attributes = _attrs(lines[selected]);
      var next = selected + 1;
      while (next < lines.length &&
          (lines[next].isEmpty || lines[next].startsWith('#'))) {
        next++;
      }
      if (next == lines.length) {
        throw const FormatException('HLS variant URL is missing.');
      }
      final output = <String>['#EXTM3U'];
      // Keep every rendition belonging to the chosen variant, including audio
      // tracks. Dropping an AUDIO group would produce a silent offline video.
      for (final line in lines.where(
        (line) => line.startsWith('#EXT-X-MEDIA:'),
      )) {
        final attrs = _attrs(line);
        if (attributes[attrs['TYPE']] != attrs['GROUP-ID']) continue;
        final value = attrs['URI'];
        if (value == null) {
          output.add(line);
          continue;
        }
        final name = 'rendition${playlists.length}_${output.length}.m3u8';
        await _playlist(_resolve(uri, value), name, depth + 1);
        output.add(_replaceUri(line, name));
      }
      final name = 'variant$depth.m3u8';
      await _playlist(_resolve(uri, lines[next]), name, depth + 1);
      output.addAll([lines[selected], name]);
      playlists[filename] = '${output.join('\n')}\n';
    } else {
      if (!lines.contains('#EXT-X-ENDLIST')) {
        throw const FormatException(
          'Live HLS streams cannot be saved for offline playback.',
        );
      }
      final output = <String>[];
      String? range;
      String? previousRangeUrl;
      int rangeEnd = 0;
      for (final line in lines) {
        if (line.startsWith('#EXT-X-BYTERANGE:')) {
          range = line.substring('#EXT-X-BYTERANGE:'.length);
          continue;
        }
        if (line.startsWith('#EXT-X-KEY:') || line.startsWith('#EXT-X-MAP:')) {
          final attrs = _attrs(line);
          if (line.startsWith('#EXT-X-KEY:') &&
              attrs['METHOD'] != 'NONE' &&
              (attrs['METHOD'] != 'AES-128' ||
                  (attrs['KEYFORMAT'] ?? 'identity') != 'identity')) {
            throw const FormatException(
              'DRM-protected HLS sources cannot be downloaded.',
            );
          }
          final value = attrs['URI'];
          if (value != null) {
            final assetUri = _resolve(uri, value);
            final mapRange = attrs['BYTERANGE'];
            final byteRange = mapRange == null ? null : _range(mapRange, 0);
            final name = _asset(
              assetUri,
              byteRange,
              expectedLength: attrs['METHOD'] == 'AES-128' ? 16 : null,
            );
            output.add(
              _replaceUri(line, name)
                  .replaceAll(
                    RegExp(r'BYTERANGE="[^"]*",?|,BYTERANGE="[^"]*"'),
                    '',
                  )
                  .replaceAll(':,', ':')
                  .replaceAll(RegExp(r',$'), ''),
            );
          } else {
            output.add(line);
          }
        } else if (line.isNotEmpty && !line.startsWith('#')) {
          final assetUri = _resolve(uri, line);
          (int, int)? byteRange;
          if (range != null) {
            if (!range.contains('@') &&
                previousRangeUrl != assetUri.toString()) {
              throw const FormatException(
                'HLS byte range has no preceding offset.',
              );
            }
            byteRange = _range(range, rangeEnd);
            rangeEnd = byteRange.$1 + byteRange.$2;
            previousRangeUrl = assetUri.toString();
            range = null;
          }
          output.add(_asset(assetUri, byteRange));
        } else {
          // Reject URI-bearing extensions we cannot make self-contained.
          if (line.contains('URI=')) {
            throw const FormatException('Unsupported HLS playlist reference.');
          }
          output.add(line);
        }
      }
      playlists[filename] = '${output.join('\n')}\n';
    }
    _visiting.remove(requestedUri.toString());
  }

  String _asset(Uri uri, (int, int)? range, {int? expectedLength}) {
    final key = '$uri|$range|$expectedLength';
    return _assetNames.putIfAbsent(key, () {
      if (assets.length >= 20000) {
        throw const FormatException('Too many HLS segments.');
      }
      final extension =
          RegExp(
            r'\.(ts|m4s|mp4|aac|vtt|key)$',
            caseSensitive: false,
          ).firstMatch(uri.path)?.group(0) ??
          '.bin';
      final filename = 'asset${assets.length}$extension';
      assets.add(
        HlsDownloadAsset(uri.toString(), filename, {
          ...headers,
          if (range != null)
            'Range': 'bytes=${range.$1}-${range.$1 + range.$2 - 1}',
        }, expectedLength ?? range?.$2),
      );
      return filename;
    });
  }

  Uri _resolve(Uri base, String path) {
    final uri = base.resolve(path);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const FormatException('Unsupported HLS resource URL.');
    }
    return uri;
  }

  (int, int) _range(String value, int offset) {
    final parts = value.split('@');
    final length = int.tryParse(parts.first);
    final start = parts.length == 1 ? offset : int.tryParse(parts.last);
    if (length == null || start == null || length <= 0 || start < 0) {
      throw const FormatException('Invalid HLS byte range.');
    }
    return (start, length);
  }

  Map<String, String> _attrs(String line) => {
    for (final match in RegExp(
      r'([A-Z0-9-]+)=("[^"]*"|[^,]*)',
    ).allMatches(line))
      match[1]!: match[2]!.replaceAll(RegExp(r'^"|"$'), ''),
  };
  String _replaceUri(String line, String value) =>
      line.replaceFirst(RegExp(r'URI="[^"]*"'), 'URI="$value"');
}
