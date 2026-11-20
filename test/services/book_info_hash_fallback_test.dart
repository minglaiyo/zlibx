import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

// Regression tests for the booklist-detail "Invalid hash" failure
// (2026-11-07): booklist/profile/shared books carry only the webpage
// short hash (from `/book/{hash}/...` links), but
// `GET /eapi/book/{id}/{hash}` wants the eapi hash, which only appears
// in eapi search responses. `getBookInfo` (and the download link
// lookup) must resolve it with a title search and retry once — and
// only on that exact error.
//
// The reference book is the real one from the report: id 5740686,
// short hash 5jJwz97pvp. The resolved hash is a stand-in: the live
// eapi hash is only known from a real search response.

const _title = '你学的数学可能是假的：超简单有趣的数学思维启蒙书';
const _bookId = '5740686';
const _shortHash = '5jJwz97pvp';
// eapi hash 的真实形状是 6 位（2026-11-21 实测：书单短 hash len=10
// 必败、eapi hash len=6 命中）——占位值按真实长度取。
const _resolvedHash = 'r3s0lv';

Map<String, dynamic> _searchPayload({bool includeTarget = true}) {
  final books = <Map<String, dynamic>>[
    {
      'id': 5288001,
      'hash': 'decoy-hash',
      'title': '世界上最简单的会计书',
      'author': '达雷尔·穆利斯',
    },
  ];
  if (includeTarget) {
    books.add({
      'id': 5740686,
      'hash': _resolvedHash,
      'title': _title,
      'author': '霍格尔·丹贝克',
    });
  }
  return {
    'success': 1,
    'books': books,
    'pagination': {'current': 1, 'total_pages': 1},
  };
}

/// Serves canned eapi responses so the fallback runs without a network.
/// Records every requested path and every search call.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({required this.searchPayload});

  Map<String, dynamic> searchPayload;

  final List<String> requestedPaths = [];
  final List<String> searchBodies = [];
  int searchCalls = 0;

  static const Map<String, dynamic> _invalidHash = {
    'success': 0,
    'error': 'Invalid hash',
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    requestedPaths.add(path);
    if (path == '/eapi/book/search') {
      searchCalls++;
      searchBodies.add(options.data?.toString() ?? '');
      return _json(searchPayload);
    }
    if (path == '/eapi/book/$_bookId/$_shortHash') {
      return _json(_invalidHash);
    }
    if (path == '/eapi/book/$_bookId/$_resolvedHash') {
      return _json({
        'success': 1,
        'book': {
          'id': 5740686,
          'hash': _resolvedHash,
          'title': _title,
          'author': '霍格尔·丹贝克',
          'extension': 'mobi',
          'language': 'Chinese',
          'year': 2019,
        },
      });
    }
    if (path == '/eapi/book/$_bookId/unknown-hash') {
      return _json({'success': 0, 'error': 'book not found'});
    }
    if (path == '/eapi/book/$_bookId/$_shortHash/file') {
      return _json(_invalidHash);
    }
    if (path == '/eapi/book/$_bookId/$_resolvedHash/file') {
      return _json({
        'success': 1,
        'downloadLink': 'https://cdn.example.com/file.mobi',
      });
    }
    if (path == '/file.mobi') {
      return ResponseBody.fromString(
        'fake-book-bytes',
        200,
        headers: {
          Headers.contentLengthHeader: ['fake-book-bytes'.length.toString()],
        },
      );
    }
    return _json({'success': 0, 'error': 'not found'}, statusCode: 404);
  }

  ResponseBody _json(Map<String, dynamic> payload, {int statusCode = 200}) {
    return ResponseBody.fromString(
      jsonEncode(payload),
      statusCode,
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
  test('fast path: a correct eapi hash costs no search call', () async {
    final adapter = _FakeAdapter(searchPayload: _searchPayload());
    final api = _apiWith(adapter);

    final res = await api.getBookInfo(_bookId, _resolvedHash, title: _title);

    expect(res.success, isTrue);
    expect(res.data!.id, 5740686);
    expect(res.data!.hash, _resolvedHash);
    expect(adapter.searchCalls, 0);
  });

  test('invalid hash: title search resolves the eapi hash and retries',
      () async {
    final adapter = _FakeAdapter(searchPayload: _searchPayload());
    final api = _apiWith(adapter);

    final res = await api.getBookInfo(_bookId, _shortHash, title: _title);

    expect(res.success, isTrue);
    expect(res.data!.hash, _resolvedHash);
    expect(adapter.searchCalls, 1);
    expect(
      adapter.searchBodies.single,
      contains('message=${Uri.encodeQueryComponent(_title)}'),
    );
    expect(adapter.requestedPaths, [
      // 短 hash 检测（len!=6）跳过了"注定失败的 fetch1"：序列变为
      // 搜索解析 → 真 hash 直取，两发而不是三发。
      '/eapi/book/search',
      '/eapi/book/$_bookId/$_resolvedHash',
    ]);
  });

  test('invalid hash without a title does not search', () async {
    final adapter = _FakeAdapter(searchPayload: _searchPayload());
    final api = _apiWith(adapter);

    final res = await api.getBookInfo(_bookId, _shortHash);

    expect(res.success, isFalse);
    expect(res.error, 'Invalid hash');
    expect(adapter.searchCalls, 0);
  });

  test('invalid hash with no id match returns the original error',
      () async {
    final adapter =
        _FakeAdapter(searchPayload: _searchPayload(includeTarget: false));
    final api = _apiWith(adapter);

    final res = await api.getBookInfo(_bookId, _shortHash, title: _title);

    expect(res.success, isFalse);
    expect(res.error, 'Invalid hash');
    expect(adapter.searchCalls, 1);
  });

  test('other failures are not retried（6 位 hash 直取，非 invalid-hash 不解析）', () async {
    final adapter = _FakeAdapter(searchPayload: _searchPayload());
    final api = _apiWith(adapter);

    // 6 位（eapi 形状）→ 直取，命中"其他失败"照旧原样返回、不解析。
    final res = await api.getBookInfo(_bookId, 'nope01', title: _title);

    expect(res.success, isFalse);
    expect(res.error, 'not found');
    expect(adapter.searchCalls, 0);
  });

  test('非 6 位未知 hash：解析命中照样取到书（旧行为是 book not found）', () async {
    final adapter = _FakeAdapter(searchPayload: _searchPayload());
    final api = _apiWith(adapter);

    final res = await api.getBookInfo(_bookId, 'unknown-hash', title: _title);

    expect(res.success, isTrue);
    expect(res.data!.hash, _resolvedHash);
    expect(adapter.searchCalls, 1);
  });

  test('download resolves the hash the same way', () async {
    final adapter = _FakeAdapter(searchPayload: _searchPayload());
    final api = _apiWith(adapter);
    final dir = await Directory.systemTemp.createTemp('zlibx_hash_fallback');
    addTearDown(() => dir.delete(recursive: true));
    final savePath = '${dir.path}/book.mobi';

    await api.downloadBook(_bookId, _shortHash, savePath, title: _title);

    expect(await File(savePath).readAsString(), 'fake-book-bytes');
    expect(adapter.searchCalls, 1);
  });
}
