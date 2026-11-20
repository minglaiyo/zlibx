import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/books_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/utils/book_detail_perf.dart';

/// 详情正文磁盘缓存（2026-11-21 诊断修复）：重开同一本书 0 请求秒开
/// ——诊断包屏上计时实证重开要 2.3~5.0s 全是重复网络。7 天 TTL 惯例
/// 同 book_detail_extras。
Book _book() => Book(
  id: 1,
  title: '缓存回归',
  description: '正文简介',
);

class _CountingApi implements ZLibraryApi {
  int detailCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  Future<ApiResponse<Book>> getBookInfo(
    String bookId,
    String hashId, {
    String? title,
  }) async {
    detailCalls++;
    return ApiResponse.ok(_book());
  }
}

BookIdentifier _identifier() => BookIdentifier(
  '1',
  'shorthash',
  title: '缓存回归',
  href: '/book/shorthash/slug.html',
);

void main() {
  Directory? hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('book_detail_cache');
    Hive.init(hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
    await Hive.openBox(HiveService.libraryBoxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir?.delete(recursive: true);
  });

  test('重开同一本书命中磁盘缓存，零请求；路由 href 仍后挂', () async {
    final api = _CountingApi();
    final container1 = ProviderContainer(
      overrides: [zlibraryApiProvider.overrideWithValue(api)],
    );
    addTearDown(container1.dispose);

    final first = await container1.read(bookDetailsProvider(_identifier()).future);
    expect(first.title, '缓存回归');
    expect(first.href, '/book/shorthash/slug.html');
    expect(api.detailCalls, 1);
    expect(bookDetailPerf.value, contains('eapi'));

    // 新容器 = 模拟重开 app：autoDispose 的内存缓存已丢，走磁盘。
    final container2 = ProviderContainer(
      overrides: [zlibraryApiProvider.overrideWithValue(api)],
    );
    addTearDown(container2.dispose);

    final second = await container2.read(bookDetailsProvider(_identifier()).future);
    expect(second.title, '缓存回归');
    expect(second.href, '/book/shorthash/slug.html');
    expect(api.detailCalls, 1, reason: '第二次必须命中磁盘缓存，不再发请求');
    expect(bookDetailPerf.value, 'eapi cache 0 请求');
  });
}
