import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/http_client.dart';

class _QueuedAdapter implements HttpClientAdapter {
  _QueuedAdapter(this.responses);

  final List<(int, String)> responses;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (status, body) = responses[requests.length - 1];
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        HttpHeaders.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final challenge = File(
    'test/fixtures/diamwall_challenge.html',
  ).readAsStringSync();
  const token = '41422B673A3F3952CFB782FA36EDD50B03028CCD9783';

  test('retries a default-rejected 503 with session and PoW cookies', () async {
    final adapter = _QueuedAdapter([
      (503, challenge),
      (200, '<h1>Results</h1>'),
    ]);
    final dio = createDio()..httpClientAdapter = adapter;

    final response = await dio.get<String>(
      'https://fake.test/s/flutter',
      options: Options(
        headers: {
          'cookie': 'remix_userid=42; remix_userkey=secret',
          'X-Test': 'kept',
        },
      ),
    );

    expect(response.data, '<h1>Results</h1>');
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.last.method, 'GET');
    expect(adapter.requests.last.headers['X-Test'], 'kept');
    expect(
      adapter.requests.last.headers['Cookie'],
      contains('remix_userid=42'),
    );
    expect(
      adapter.requests.last.headers['Cookie'],
      contains('remix_userkey=secret'),
    );
    expect(adapter.requests.last.headers['Cookie'], contains('c_token=$token'));
    expect(adapter.requests.last.headers['Cookie'], contains('c_time='));
  });

  test('retries when per-request validateStatus accepts the 503', () async {
    final adapter = _QueuedAdapter([
      (503, challenge),
      (200, '<h1>Results</h1>'),
    ]);
    final dio = createDio()..httpClientAdapter = adapter;

    final response = await dio.post<String>(
      'https://fake.test/eapi/search',
      data: 'q=flutter',
      options: Options(
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );

    expect(response.statusCode, 200);
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.last.method, 'POST');
    expect(adapter.requests.last.data, 'q=flutter');
    expect(adapter.requests.last.extra['zlibx.diamwall_retried'], isTrue);
  });

  test('retries at most once when the challenge persists', () async {
    final adapter = _QueuedAdapter([(503, challenge), (503, challenge)]);
    final dio = createDio()..httpClientAdapter = adapter;

    await expectLater(
      dio.get<String>('https://fake.test/s/flutter'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.requests, hasLength(2));
  });

  test('does not solve plain HTTP or unrelated 503 responses', () async {
    final httpAdapter = _QueuedAdapter([(503, challenge)]);
    final httpDio = createDio()..httpClientAdapter = httpAdapter;
    await expectLater(
      httpDio.get<String>('http://fake.test/s/flutter'),
      throwsA(isA<DioException>()),
    );
    expect(httpAdapter.requests, hasLength(1));

    final errorAdapter = _QueuedAdapter([(503, '<h1>Maintenance</h1>')]);
    final errorDio = createDio()..httpClientAdapter = errorAdapter;
    await expectLater(
      errorDio.get<String>('https://fake.test/s/flutter'),
      throwsA(isA<DioException>()),
    );
    expect(errorAdapter.requests, hasLength(1));
  });
}
