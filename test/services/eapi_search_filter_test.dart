import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

// Regression tests for the advanced-search format / language filter
// (device-reported 2026-11-12: EPUB picked, PDF results came back).
// `/eapi/book/search` parses list filters ONLY in the PHP-style
// bracket form the official Android client sends
// (`languages[]=german&extensions[]=epub` — baroxyton's captured
// requests); the bare repeated keys the form encoder used to emit
// were silently dropped by the server's array parser, so the search
// screen's filter did nothing. The wire form is asserted here exactly
// as a urlencoded body carries it (`extensions%5B%5D=epub`), the same
// encoding Python's `urlencode` produces for the working eapi clients.

const _searchPayload = {
  'success': 1,
  'books': <Map<String, dynamic>>[],
  'pagination': {'current': 1, 'total_pages': 1},
};

/// Serves a canned search response and records the raw request body
/// of every search POST.
class _FakeAdapter implements HttpClientAdapter {
  final List<String> searchBodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/eapi/book/search') {
      searchBodies.add(options.data?.toString() ?? '');
      return ResponseBody.fromString(
        jsonEncode(_searchPayload),
        200,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );
    }
    return ResponseBody.fromString(
      jsonEncode({'success': 0, 'error': 'not found'}),
      404,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

ZLibraryApi _apiWith(_FakeAdapter adapter) {
  return ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);
}

void main() {
  test('extension filter goes out as repeated bracket keys', () async {
    final adapter = _FakeAdapter();
    await _apiWith(adapter).search(message: 'q', extensions: ['epub']);
    expect(adapter.searchBodies.single, contains('extensions%5B%5D=epub'));
    // The bare form must not appear anywhere — the server drops it,
    // which is what left other formats in an EPUB-filtered search.
    expect(adapter.searchBodies.single, isNot(contains('extensions=')));
  });

  test('language filter goes out as repeated bracket keys', () async {
    final adapter = _FakeAdapter();
    await _apiWith(adapter).search(message: 'q', languages: ['chinese']);
    expect(adapter.searchBodies.single, contains('languages%5B%5D=chinese'));
    expect(adapter.searchBodies.single, isNot(contains('languages=')));
  });

  test('multiple values repeat the bracket key', () async {
    final adapter = _FakeAdapter();
    await _apiWith(adapter).search(
      message: 'q',
      extensions: ['epub', 'pdf'],
    );
    expect(
      adapter.searchBodies.single,
      contains('extensions%5B%5D=epub&extensions%5B%5D=pdf'),
    );
  });

  test('the full filtered request keeps the official client form',
      () async {
    final adapter = _FakeAdapter();
    await _apiWith(adapter).search(
      message: 'q',
      languages: ['chinese'],
      extensions: ['epub'],
      page: 2,
      limit: 20,
      exact: true,
    );
    expect(
      adapter.searchBodies.single,
      'message=q'
      '&languages%5B%5D=chinese'
      '&extensions%5B%5D=epub'
      '&page=2'
      '&limit=20'
      '&e=1',
    );
  });

  test('a filterless search sends no list keys at all', () async {
    final adapter = _FakeAdapter();
    await _apiWith(adapter).search(message: 'q', limit: 5);
    expect(adapter.searchBodies.single, 'message=q&limit=5');
  });
}
