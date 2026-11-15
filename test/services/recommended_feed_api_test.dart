import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

// 个性化推荐（/eapi/user/book/recommended）不再静默改走热门接口
//（用户 2026-11-15 定：与热门页冲突了）。这里守的是去掉兜底之后的
// 两条分界：请求本身没成 → 失败（首页显示错误 + 重试）；请求成功但
// 列表为空 → 空列表（新账号没有历史，是合法结果，首页显示空状态）。
// 关键是四种情况下都不得再碰 /eapi/book/most_popular——那条链路一旦
// 复活，编译期符号还在、测试全绿、只有对比首页和热门页内容才发现。

const _recommendedPath = '/eapi/user/book/recommended';
const _mostPopularPath = '/eapi/book/most_popular';

Map<String, dynamic> _book(int id, String title) => {
  'id': id,
  'title': title,
  'author': '作者$id',
};

/// Serves canned eapi answers and records every path it was asked for.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({this.status = 200, required this.body});

  final int status;
  final Map<String, dynamic> body;
  final List<String> paths = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.path);
    // 热门接口一旦被调用就返回一份明显不同的内容，测试据此判定
    // "兜底复活了"，而不是靠数请求次数。
    final payload = options.uri.path == _mostPopularPath
        ? {
            'success': 1,
            'books': [_book(999999, '热门兜底书')],
          }
        : body;
    return ResponseBody.fromString(
      jsonEncode(payload),
      options.uri.path == _mostPopularPath ? 200 : status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ZLibraryApi _apiWith(_FakeAdapter adapter) =>
    ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);

void main() {
  test('成功且有书：原样返回，不查热门', () async {
    final adapter = _FakeAdapter(
      body: {
        'success': 1,
        'books': [_book(1, '第一本'), _book(2, '第二本')],
      },
    );
    final response = await _apiWith(adapter).getUserRecommended();
    expect(response.success, isTrue);
    expect(response.data?.map((b) => b.title), ['第一本', '第二本']);
    expect(adapter.paths, [_recommendedPath]);
  });

  test('成功但列表为空：算空结果，不算失败、不查热门', () async {
    final adapter = _FakeAdapter(body: {'success': 1, 'books': []});
    final response = await _apiWith(adapter).getUserRecommended();
    expect(response.success, isTrue);
    expect(response.data, isEmpty);
    expect(adapter.paths, [_recommendedPath]);
  });

  test('404：报失败，不查热门', () async {
    final adapter = _FakeAdapter(
      status: 404,
      body: {'success': 0, 'error': 'not found'},
    );
    final response = await _apiWith(adapter).getUserRecommended();
    expect(response.success, isFalse);
    expect(adapter.paths, [_recommendedPath]);
  });

  test('success:0：报失败并把原因带出来，不查热门', () async {
    final adapter = _FakeAdapter(
      body: {'success': 0, 'error': 'quota exceeded'},
    );
    final response = await _apiWith(adapter).getUserRecommended();
    expect(response.success, isFalse);
    expect(response.error, contains('quota exceeded'));
    expect(adapter.paths, [_recommendedPath]);
  });

  test('没有可解析的 body：报失败，不查热门', () async {
    final adapter = _EmptyBodyAdapter();
    final response = await ZLibraryApi(
      dio: Dio()..httpClientAdapter = adapter,
    ).getUserRecommended();
    expect(response.success, isFalse);
    expect(adapter.paths, [_recommendedPath]);
  });
}

/// Answers 200 with an empty body: the "null-body" branch.
class _EmptyBodyAdapter implements HttpClientAdapter {
  final List<String> paths = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.path);
    return ResponseBody.fromString(
      '',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
