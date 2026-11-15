import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/external_logger.dart';

/// Debug-log redaction for the external book sources (module 2 ④).
///
/// `createDioWithLogging` is the Dio the slum catalogue and the LibGen /
/// Anna's Archive clients run on. Dio's LogInterceptor prints both header
/// sets by default, and a debug logcat is readable by anything on the
/// device and travels with bug reports — so it would carry the slum
/// participation key outbound and a `set-cookie` session pair inbound.
/// The structured interceptor above already logs host + method + status,
/// which is all the console needs.
void main() {
  test('the debug log interceptor prints no headers or bodies', () {
    final printed = createDioWithLogging()
        .interceptors
        .whereType<LogInterceptor>()
        .toList();

    // flutter test runs a debug build, so the kDebugMode branch is live.
    expect(printed, hasLength(1));
    final log = printed.single;
    expect(log.requestHeader, isFalse, reason: 'Cookie / participation key');
    expect(log.responseHeader, isFalse, reason: 'set-cookie session pair');
    expect(log.requestBody, isFalse, reason: 'login form fields');
    expect(log.responseBody, isFalse);
  });
}
