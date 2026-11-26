import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

// Destructive-GET tests (plan item 5): booklist remove / delete go
// through a dedicated client that makes exactly one attempt and only
// ever follows the DDoS-Guard challenge hop (307 + DiamWall markers,
// same URL). Anything else — another redirect, a transport error —
// fails without a resend.

class _Planned {
  final int status;
  final String body;
  final Map<String, List<String>> headers;
  final bool throwConnectionError;

  const _Planned(
    this.status,
    this.body, [
    this.headers = const {},
    this.throwConnectionError = false,
  ]);
}

class _FakeAdapter implements HttpClientAdapter {
  /// path -> responses served in order.
  final Map<String, List<_Planned>> scripts = {};
  final List<RequestOptions> requests = [];

  void script(String path, List<_Planned> responses) {
    scripts[path] = List.of(responses);
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final queue = scripts[options.uri.path];
    if (queue == null || queue.isEmpty) {
      return ResponseBody.fromString(
        jsonEncode({'success': 0, 'error': 'not found'}),
        404,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );
    }
    final planned = queue.removeAt(0);
    if (planned.throwConnectionError) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: 'Connection failed',
      );
    }
    return ResponseBody.fromString(
      planned.body,
      planned.status,
      headers: planned.headers,
    );
  }

  @override
  void close({bool force = false}) {}
}

const _removePath = '/papi/booklist/1/remove-book/5';
const _deletePath = '/papi/booklist/1/delete';

ZLibraryApi _apiWith(_FakeAdapter adapter) {
  return ZLibraryApi(
    dio: Dio()..httpClientAdapter = adapter,
    destructiveDio: Dio()..httpClientAdapter = adapter,
  );
}

void main() {
  test('remove follows the DiamWall challenge hop once, then succeeds',
      () async {
    final adapter = _FakeAdapter();
    adapter.script(_removePath, [
      const _Planned(307, '', {
        'location': [_removePath],
        'set-cookie': ['__diamwall=abc; Path=/'],
      }),
      const _Planned(200, '{"success":1}', {
        Headers.contentTypeHeader: ['application/json'],
      }),
    ]);
    final api = _apiWith(adapter);
    final result = await api.removeBookFromBooklist(
      booklistId: 1,
      readlistBookId: 5,
    );
    expect(result.success, isTrue);
    expect(result.data, isTrue);
    expect(adapter.requests, hasLength(2));
    // The follow-up carries the challenge cookie the 307 set.
    final cookie = adapter.requests[1].headers['Cookie']?.toString() ?? '';
    expect(cookie, contains('__diamwall=abc'));
  });

  test('remove does not follow a 302 to another host', () async {
    final adapter = _FakeAdapter();
    adapter.script(_removePath, [
      const _Planned(302, '', {
        'location': ['https://other.example/x'],
      }),
    ]);
    final result = await _apiWith(adapter).removeBookFromBooklist(
      booklistId: 1,
      readlistBookId: 5,
    );
    expect(result.success, isFalse);
    expect(result.error, contains('redirect not followed'));
    expect(adapter.requests, hasLength(1));
  });

  test('remove does not follow a 301 on the same host', () async {
    final adapter = _FakeAdapter();
    adapter.script(_removePath, [
      const _Planned(301, '', {
        'location': [_removePath],
      }),
    ]);
    final result = await _apiWith(adapter).removeBookFromBooklist(
      booklistId: 1,
      readlistBookId: 5,
    );
    expect(result.success, isFalse);
    expect(adapter.requests, hasLength(1));
  });

  test('a connection error is a single attempt, never retried', () async {
    final adapter = _FakeAdapter();
    adapter.script(_removePath, [
      const _Planned(0, '', {}, true),
    ]);
    final result = await _apiWith(adapter).removeBookFromBooklist(
      booklistId: 1,
      readlistBookId: 5,
    );
    expect(result.success, isFalse);
    expect(adapter.requests, hasLength(1));
  });

  test('the challenge hop is followed at most 3 times', () async {
    final adapter = _FakeAdapter();
    adapter.script(_removePath, [
      for (var i = 0; i < 4; i++)
        const _Planned(307, '', {
          'location': [_removePath],
          'set-cookie': ['__diamwall=abc; Path=/'],
        }),
    ]);
    final result = await _apiWith(adapter).removeBookFromBooklist(
      booklistId: 1,
      readlistBookId: 5,
    );
    expect(result.success, isFalse);
    expect(result.error, contains('redirect not followed'));
    expect(adapter.requests, hasLength(4));
  });

  test('delete does not follow a 307 without DiamWall markers', () async {
    final adapter = _FakeAdapter();
    adapter.script(_deletePath, [
      const _Planned(307, '', {
        'location': [_deletePath],
      }),
    ]);
    final result = await _apiWith(adapter).deleteBooklist(1);
    expect(result.success, isFalse);
    expect(adapter.requests, hasLength(1));
  });

  test('delete with an empty 2xx body still counts as removed', () async {
    final adapter = _FakeAdapter();
    adapter.script(_deletePath, [const _Planned(200, '')]);
    final result = await _apiWith(adapter).deleteBooklist(1);
    expect(result.success, isTrue);
    expect(result.data, isTrue);
    expect(adapter.requests, hasLength(1));
  });
}
