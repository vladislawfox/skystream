import 'package:dio/dio.dart';

/// URLSession exposes the final URL but not a complete redirect history.
/// Keep it separately instead of inventing Dio redirect status/method records.
const nativeResponseUriKey = 'skystream.nativeResponseUri';

Uri effectiveResponseUri(Response<dynamic> response) =>
    response.extra[nativeResponseUriKey] as Uri? ?? response.realUri;
