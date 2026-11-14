import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/utils/diagnostics.dart';

void main() {
  setUp(Diagnostics.clear);

  test('records tag and exception type only, never the message', () {
    logIgnored('unit', const FormatException('cookie=SECRET'));
    final dump = Diagnostics.dump();
    expect(dump, contains('[unit] FormatException'));
    expect(dump, isNot(contains('SECRET')));
  });

  test('ring buffer is bounded and drops the oldest first', () {
    for (var i = 0; i < Diagnostics.maxEntries + 25; i++) {
      logIgnored('t$i', StateError('x'));
    }
    final snap = Diagnostics.snapshot();
    expect(snap.length, Diagnostics.maxEntries);
    expect(snap.first, contains('[t25]'));
  });

  test('records the topmost package:zlibx frame when a stack is passed (O7)',
      () {
    final stack = StackTrace.fromString(
      '#0 Foo.bar (package:flutter/src/widgets/framework.dart:100:20)\n'
      '#1 Baz.qux (package:zlibx/services/foo.dart:123:45)\n'
      '#2 Quux.zap (package:zlibx/services/bar.dart:9:1)',
    );
    logIgnored('unit', StateError('secret-message'), stack: stack);
    final dump = Diagnostics.dump();
    // Only the TOPMOST zlibx frame (file:line), never the message or
    // the rest of the stack.
    expect(dump, contains('package:zlibx/services/foo.dart:123'));
    expect(dump, isNot(contains('services/bar.dart')));
    expect(dump, isNot(contains('secret-message')));
    expect(dump, isNot(contains('framework.dart')));
  });

  test('records no frame when the stack has no package:zlibx frame (O7)',
      () {
    final stack = StackTrace.fromString(
      '#0 Foo.bar (package:flutter/src/widgets/framework.dart:100:20)',
    );
    logIgnored('unit', StateError('x'), stack: stack);
    final dump = Diagnostics.dump();
    expect(dump, contains('[unit] StateError'));
    expect(dump, isNot(contains('package:zlibx')));
  });

  test('records the HTTP status of a network error (O7)', () {
    final dioError = DioException(
      requestOptions: RequestOptions(path: '/eapi/book/1/abc'),
      response: Response<String>(
        requestOptions: RequestOptions(path: '/eapi/book/1/abc'),
        statusCode: 503,
      ),
    );
    logIgnored('unit', dioError);
    final dump = Diagnostics.dump();
    expect(dump, contains('[unit] DioException'));
    expect(dump, contains('HTTP 503'));
    // The request URL is never recorded.
    expect(dump, isNot(contains('/eapi/book')));
  });
}
