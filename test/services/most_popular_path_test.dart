import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

/// getMostPopular 的路径双拼（2026-11-20 探测）：真身是连字符
/// `/eapi/book/most-popular`（bookroom.lifestyle 实测 success:1 出书），
/// vendor 历史上的下划线拼写在真身上 400——热门页因此一直走 popular
/// 排序搜索的回退。现在两个拼写都试，都不行才回退；社区镜像可能只
/// 认其中一种。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({required this.workingSpelling});

  /// 哪个 most-popular 拼写返回真数据：dash / underscore / none。
  final String workingSpelling;

  final List<String> requestedPaths = [];
  int searchCalls = 0;

  Map<String, dynamic> get _booksPayload => {
    'success': 1,
    'books': [
      {
        'id': 118429543,
        'hash': '6kdxG66akK',
        'title': 'The Autobiography of Red',
        'author': 'Anne Carson',
      },
    ],
    'pagination': {'current': 1, 'total_pages': 3},
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
      return _json({
        'success': 1,
        'books': [
          {'id': 1, 'hash': 'h1', 'title': 'fallback book', 'author': 'a'},
        ],
        'pagination': {'current': 1, 'total_pages': 1},
      });
    }
    final isDash = path == '/eapi/book/most-popular';
    final isUnderscore = path == '/eapi/book/most_popular';
    if (isDash && workingSpelling == 'dash') return _json(_booksPayload);
    if (isUnderscore && workingSpelling == 'underscore') {
      return _json(_booksPayload);
    }
    if (isDash || isUnderscore) {
      // 真身对下划线拼写的回答形态（2026-11-20 实测）：JSON 壳 400。
      return _json(
        const {'success': 0, 'error': 'Requested book not found'},
        statusCode: 400,
      );
    }
    return _json(const {'success': 0, 'error': 'not found'}, statusCode: 404);
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
  test('连字符拼写可用：一次请求出书，不走搜索回退', () async {
    final adapter = _FakeAdapter(workingSpelling: 'dash');
    final res = await _apiWith(adapter).getMostPopular(page: 1);

    expect(res.success, isTrue);
    expect(res.data!.first.id, 118429543);
    expect(adapter.searchCalls, 0);
    expect(adapter.requestedPaths.first, '/eapi/book/most-popular');
    expect(adapter.requestedPaths.length, 1);
  });

  test('镜像只认下划线：换第二个拼写出书，仍不走搜索回退', () async {
    final adapter = _FakeAdapter(workingSpelling: 'underscore');
    final res = await _apiWith(adapter).getMostPopular();

    expect(res.success, isTrue);
    expect(res.data!.first.id, 118429543);
    expect(adapter.searchCalls, 0);
    expect(adapter.requestedPaths, [
      '/eapi/book/most-popular',
      '/eapi/book/most_popular',
    ]);
  });

  test('两个拼写都不行：照旧回退 popular 排序搜索', () async {
    final adapter = _FakeAdapter(workingSpelling: 'none');
    final res = await _apiWith(adapter).getMostPopular(page: 2);

    expect(res.success, isTrue);
    expect(res.data!.first.id, 1);
    expect(adapter.searchCalls, 1);
    // 两个拼写各试一次后才回退(search 也记录在 requestedPaths 里)。
    expect(
      adapter.requestedPaths.where((p) => p != '/eapi/book/search').length,
      2,
    );
  });
}
