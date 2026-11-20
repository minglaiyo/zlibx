import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

/// 短 hash → eapi 真 hash 的解析映射（2026-11-21 诊断修复）：首次
/// 打开短 hash 书是"必失败的 fetch1 + 按标题解析 + 重取"三连发
/// （诊断包屏上计时实证每次重开 2.3~5.0s）；解析映射持久化后，之后
/// 每次打开直接用真 hash，一发命中。本测试用真实 [ZLibraryApi] +
/// Dio 桩适配器打穿 vendor 内部（假 API 会绕过被测代码）。
class _StubAdapter implements HttpClientAdapter {
  final List<String> bookPaths = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    // 注意：解析用的搜索端点是 /eapi/book/search，也带 /eapi/book/
    // 前缀——先排除它，剩下的才是取书请求。
    if (path.contains('/eapi/book/') && !path.contains('/eapi/book/search')) {
      bookPaths.add(path);
      final body = path.endsWith('/short')
          ? {'success': 0, 'error': 'Invalid hash'}
          : {
              'success': 1,
              'book': {'id': 123, 'hash': 'realhash', 'title': '书'},
            };
      return ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );
    }
    // resolveEapiHash 走的搜索：返回带真 hash 的同 id 书。
    return ResponseBody.fromString(
      jsonEncode({
        'success': 1,
        'books': [
          {'id': 123, 'hash': 'realhash', 'title': '书'},
        ],
      }),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }
}

void main() {
  final resolveMap = <String, String>{};
  void Function(String, String, String)? savedWrite;

  setUp(() {
    resolveMap.clear();
    // 静态钩子是全局的：保存原值，tearDown 恢复，别漏给别的测试。
    savedWrite = ZLibraryApiBase.resolveCacheWrite;
    ZLibraryApiBase.resolveCacheLookup = (bookId, hash) async {
      return resolveMap['$bookId:$hash'];
    };
    ZLibraryApiBase.resolveCacheWrite = (bookId, hash, resolved) {
      resolveMap['$bookId:$hash'] = resolved;
    };
  });

  tearDown(() {
    ZLibraryApiBase.resolveCacheLookup = null;
    ZLibraryApiBase.resolveCacheWrite = savedWrite;
  });

  test('首次打开短 hash 书：三连发后映射落库', () async {
    final adapter = _StubAdapter();
    final api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);

    final response = await api.getBookInfo('123', 'short', title: '书');

    expect(response.success, isTrue, reason: 'error=${response.error}');
    expect(resolveMap['123:short'], 'realhash');
    // 三连发：短 hash（注定失败）→ 按标题搜索解析 → 真 hash 重取。
    expect(
      adapter.bookPaths,
      ['/eapi/book/123/short', '/eapi/book/123/realhash'],
    );
  });

  test('映射命中后重开：一发直取真 hash，不再解析', () async {
    resolveMap['123:short'] = 'realhash';
    final adapter = _StubAdapter();
    final api = ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);

    final response = await api.getBookInfo('123', 'short', title: '书');

    expect(response.success, isTrue);
    expect(adapter.bookPaths, ['/eapi/book/123/realhash']);
  });
}
