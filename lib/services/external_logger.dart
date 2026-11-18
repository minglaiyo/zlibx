// Minimal logger shim for the ported external book sources (Anna's Archive
// / LibGen, from warreth/OpenlibExtended). OpenlibExtended's logger writes
// to a rolling file and shares logs; zlibx keeps it debugPrint-only —
// no file_picker / path_provider / share_plus needed.
//
// This is NOT a port of OpenlibExtended's lib/services/logger.dart; it only
// provides the AppLogger API surface that the ported files call, plus
// createDioWithLogging (used by SlumCatalogue).

// Package imports:
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../utils/app_log.dart';
import 'http_client.dart';

/// A minimal stand-in for OpenlibExtended's AppLogger: the ported services
/// only need the four level methods plus a way to build a Dio that logs.
/// Single shared instance so the static-ish call sites stay identical.
///
/// The level methods are thin delegations to [AppLog] (see
/// utils/app_log.dart): same signatures, same debug-only gating, same
/// `[LEVEL][tag] message | error | metadata` format. Nothing about the
/// call sites changes.
class AppLogger {
  static final AppLogger _instance = AppLogger._();
  factory AppLogger() => _instance;
  AppLogger._();

  void debug(String message, {String? tag, Map<String, dynamic>? metadata}) {
    AppLog.debug(message, tag: tag, metadata: metadata);
  }

  void info(String message, {String? tag, Map<String, dynamic>? metadata}) {
    AppLog.info(message, tag: tag, metadata: metadata);
  }

  void warning(
    String message, {
    String? tag,
    dynamic error,
    Map<String, dynamic>? metadata,
  }) {
    AppLog.warning(message, tag: tag, error: error, metadata: metadata);
  }

  void error(
    String message, {
    String? tag,
    dynamic error,
    StackTrace? stackTrace,
    Map<String, dynamic>? metadata,
  }) {
    AppLog.error(
      message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
      metadata: metadata,
    );
  }
}

/// Builds a [Dio] wired with the same logging behaviour the ported
/// SlumCatalogue expects: request/response logging plus per-request timing.
/// (Mirrors OpenlibExtended's createDioWithLogging, minus the file log.)
///
/// The client itself is built by [createDio] (see http_client.dart) so
/// timeouts, headers and redirects stay in one place; only the timing
/// interceptors are added here. Logs carry host + method + status only,
/// never the full URL — LibGen links can carry a `key=` query parameter.
Dio createDioWithLogging({BaseOptions? options}) {
  final dio = createDio(
    connectTimeout: options?.connectTimeout ?? const Duration(seconds: 15),
    receiveTimeout: options?.receiveTimeout ?? const Duration(seconds: 30),
    headers: options?.headers,
  );
  if (options != null) {
    dio.options.followRedirects = options.followRedirects;
    dio.options.maxRedirects = options.maxRedirects;
  }
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (req, handler) {
        req.extra['request_time'] = DateTime.now().millisecondsSinceEpoch;
        handler.next(req);
      },
      onResponse: (resp, handler) {
        final start = resp.requestOptions.extra['request_time'] as int?;
        final ms = start == null
            ? -1
            : DateTime.now().millisecondsSinceEpoch - start;
        AppLogger().debug(
          'HTTP ${resp.statusCode} ${resp.requestOptions.method} '
          '${resp.requestOptions.uri.host} (${ms}ms)',
          tag: 'Dio',
        );
        handler.next(resp);
      },
      onError: (err, handler) {
        final start = err.requestOptions.extra['request_time'] as int?;
        final ms = start == null
            ? -1
            : DateTime.now().millisecondsSinceEpoch - start;
        AppLogger().warning(
          'HTTP error ${err.response?.statusCode} '
          '${err.requestOptions.method} ${err.requestOptions.uri.host} '
          '(${ms}ms)',
          tag: 'Dio',
          error: err.message,
        );
        handler.next(err);
      },
    ),
  );
  if (kDebugMode) {
    // URL, method, status lines only. Dio prints both header sets by
    // default (bodies are already off): that is the slum participation key
    // on the way out and a `set-cookie` with a session pair on the way back,
    // in a logcat any app on the device — and every bug report — can read.
    // Singular spellings: dio 5.9.2's LogInterceptor uses `requestHeader` /
    // `responseHeader`.
    dio.interceptors.add(
      LogInterceptor(requestHeader: false, responseHeader: false),
    );
  }
  return dio;
}
