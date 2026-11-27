import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/services/http_client.dart';

/// Review-2 P2-1: one User-Agent source per client.
///
/// The Z-Library client sends exactly one default UA
/// ([kZLibraryUserAgent], mobile Chrome) from its read client, its
/// destructive client, and the per-request headers — the three used to
/// carry three copies of the same string. Once a wall solve records
/// the WebView's real UA, the Dio path replays THAT UA
/// ([ZLibraryApiBase.setWallUserAgent], fed by
/// `wall_cookie_bridge.dart` from
/// `WebviewChallengeSolver.wallUserAgentFor`): the clearance was
/// minted against it, so the solver path and the Dio path must agree.
/// The solver's capture itself needs a live WebView and is not
/// unit-testable here; what this pins is the Dio side of the contract
/// — set the solver UA once, every later request carries it.
///
/// The app's non-Z-Library clients share their own single constant
/// ([kDefaultUserAgent], desktop Chrome) via [createDio].
class _HeaderCapturingAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> requestedHeaders = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedHeaders.add(Map<String, dynamic>.from(options.headers));
    return ResponseBody.fromString(
      jsonEncode({
        'success': 1,
        'user': {
          'id': '35899435',
          'email': 'reader@example.com',
          'name': 'Reader',
          'remixUserkey': 'sessionkey-abc123',
        },
      }),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

ZLibraryApi _apiWith(_HeaderCapturingAdapter adapter) {
  return ZLibraryApi(
    dio: Dio()..httpClientAdapter = adapter,
    destructiveDio: Dio()..httpClientAdapter = adapter,
  );
}

void main() {
  group('Z-Library client User-Agent (P2-1)', () {
    test('read client sends the single default UA', () async {
      final adapter = _HeaderCapturingAdapter();
      final api = _apiWith(adapter);
      final response = await api.getProfile();
      expect(response.success, isTrue);
      expect(adapter.requestedHeaders, hasLength(1));
      expect(
        adapter.requestedHeaders.single['User-Agent'],
        kZLibraryUserAgent,
      );
    });

    test('destructive client sends the same default UA', () async {
      final adapter = _HeaderCapturingAdapter();
      final api = _apiWith(adapter);
      final response = await api.deleteBooklist(4095945);
      expect(response.success, isTrue);
      expect(adapter.requestedHeaders, hasLength(1));
      expect(
        adapter.requestedHeaders.single['User-Agent'],
        kZLibraryUserAgent,
      );
    });

    test('solver UA, once set, replaces the default on both clients',
        () async {
      const solverUa =
          'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
      final adapter = _HeaderCapturingAdapter();
      final api = _apiWith(adapter);
      api.setWallUserAgent(solverUa);
      await api.getProfile();
      await api.deleteBooklist(4095945);
      expect(adapter.requestedHeaders, hasLength(2));
      for (final headers in adapter.requestedHeaders) {
        expect(headers['User-Agent'], solverUa);
      }
    });

    test('empty solver UA is ignored, default stays', () async {
      final adapter = _HeaderCapturingAdapter();
      final api = _apiWith(adapter);
      api.setWallUserAgent('   ');
      await api.getProfile();
      expect(
        adapter.requestedHeaders.single['User-Agent'],
        kZLibraryUserAgent,
      );
    });
  });

  group('app clients User-Agent (P2-1)', () {
    test('createDio sends the single desktop UA', () {
      final dio = createDio();
      expect(dio.options.headers['User-Agent'], kDefaultUserAgent);
    });
  });
}
