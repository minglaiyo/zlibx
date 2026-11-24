import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

// Regression test for the dead eapi search (2026-11-24): Z-Library's
// mobile eapi requires a `source: android` header on every request.
// Without it, POST /eapi/book/search answers HTTP 400
// `{"success":0,"error":"Access denied"}` even with a valid session,
// while login / profile / popular are unaffected (qgming/zlib-app
// ADR-076; heartleo/zlib v0.0.16). The fake adapter records the header
// the search request actually carried.

class _SourceHeaderAdapter implements HttpClientAdapter {
  final List<String?> sourceHeaders = [];
  final List<String> requestedPaths = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedPaths.add(options.uri.path);
    sourceHeaders.add(options.headers['source'] as String?);
    final payload = options.uri.path == '/eapi/book/search'
        ? {
            'success': 1,
            'books': [],
            'pagination': {'current': 1, 'total_pages': 0},
          }
        : {
            'success': 1,
            'book': {
              'id': 26610712,
              'hash': 'Ej8q7D',
              'title': '三体',
              'author': '刘慈欣',
              'extension': 'epub',
              'language': 'Chinese',
              'year': 2008,
            },
          };
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('eapi search carries source: android', () async {
    final adapter = _SourceHeaderAdapter();
    final api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);
    final res = await api.search(message: 'test', limit: 1);
    expect(res.success, isTrue);
    expect(adapter.requestedPaths, contains('/eapi/book/search'));
    expect(adapter.sourceHeaders, everyElement('android'));
  });

  test('eapi detail carries source: android', () async {
    final adapter = _SourceHeaderAdapter();
    final api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);
    await api.getBookInfo('26610712', 'Ej8q7D');
    expect(adapter.requestedPaths, contains('/eapi/book/26610712/Ej8q7D'));
    expect(adapter.sourceHeaders, everyElement('android'));
  });
}
