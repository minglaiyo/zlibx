// Shared Dio factory for the app's own HTTP clients.
//
// Every ad-hoc `Dio()` in lib/ used to configure its own timeouts (or
// none at all) and its own User-Agent. Use [createDio] instead so all
// non-plugin clients share one sane baseline: a 10s connect timeout,
// 30s send/receive timeouts, and a desktop-Chrome User-Agent (several
// mirrors and feeds reject bare Dart clients).
//
// Exceptions, do not "fix" them:
// - `vendor/olib_api_plugin` keeps its own Dio (cookie + baseUrl); it
//   is the Z-Library client core and must not go through this factory.
// - Downloads pass `receiveTimeout: null` (no receive timeout): the
//   stream must survive slow networks; the connect timeout stays.
// - Per-request `Options` still override these instance defaults
//   (e.g. the Open Library feed's 5s/20s timeouts).
import 'package:dio/dio.dart';

/// Desktop-Chrome User-Agent shared by the app's HTTP clients.
const String kDefaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 '
    'Safari/537.36';

/// Build a Dio with the shared baseline. Pass `receiveTimeout: null`
/// for downloads (unlimited receive, connect timeout kept).
Dio createDio({
  Duration connectTimeout = const Duration(seconds: 10),
  Duration sendTimeout = const Duration(seconds: 30),
  Duration? receiveTimeout = const Duration(seconds: 30),
  Map<String, dynamic>? headers,
}) {
  return Dio(
    BaseOptions(
      connectTimeout: connectTimeout,
      sendTimeout: sendTimeout,
      receiveTimeout: receiveTimeout,
      headers: {'User-Agent': kDefaultUserAgent, ...?headers},
    ),
  );
}
