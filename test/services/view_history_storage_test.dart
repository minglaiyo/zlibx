import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/view_history_storage.dart';
import 'package:zlibx/utils/date_text.dart';

/// [ViewHistoryStore]（本地浏览历史）与 [formatViewedAt] 的时间格式。
///
/// Hive box 用临时目录手工打开（与 booklist_detail_remove_test 同法）；
/// Windows 上 Hive 持有句柄，tearDownAll 先 close 再删目录。
void main() {
  Directory? tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('view_history');
    Hive.init(tempDir!.path);
    await Hive.openBox(HiveService.viewHistoryBoxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir?.delete(recursive: true);
  });

  tearDown(() async {
    await HiveService.viewHistoryBox.clear();
  });

  Book book(int id, {String? hash}) => Book(
        id: id,
        title: 'Book $id',
        hash: hash ?? 'hash$id',
        author: 'Author $id',
        extension: 'pdf',
        year: 2024,
      );

  test('add + entries：按 viewedAt 倒序，Book 无损往返', () async {
    ViewHistoryStore.add(book(1));
    // 两次 add 可能落在同一毫秒，先隔开保证顺序断言稳定。
    await Future<void>.delayed(const Duration(milliseconds: 5));
    ViewHistoryStore.add(book(2));

    final list = ViewHistoryStore.entries();
    expect(list.map((e) => e.book.id), [2, 1]);
    // 往返保真：重开的详情页要能带着 hash/id/作者等重建路由参数。
    expect(list[1].book.hash, 'hash1');
    expect(list[1].book.title, 'Book 1');
    expect(list[1].book.author, 'Author 1');
  });

  test('add：同书重读置顶并刷新时间，不产生重复条目', () async {
    ViewHistoryStore.add(book(1));
    ViewHistoryStore.add(book(2));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    ViewHistoryStore.add(book(1));

    final list = ViewHistoryStore.entries();
    expect(list.length, 2);
    expect(list.first.book.id, 1);
    // 重读后时间戳被刷新：晚于第二条的原始时间。
    expect(list.first.viewedAt.isAfter(list[1].viewedAt), isTrue);
  });

  test('add：超过上限淘汰最旧条目', () {
    for (var i = 1; i <= ViewHistoryStore.maxEntries + 10; i++) {
      ViewHistoryStore.add(book(i));
    }
    final list = ViewHistoryStore.entries();
    expect(list.length, ViewHistoryStore.maxEntries);
    // 最旧的 1..10 被淘汰，最新一条是 maxEntries+10。
    expect(list.first.book.id, ViewHistoryStore.maxEntries + 10);
    expect(
      list.map((e) => e.book.id),
      isNot(contains(1)),
    );
  });

  test('clear：清空后 entries 为空', () async {
    ViewHistoryStore.add(book(1));
    await ViewHistoryStore.clear();
    expect(ViewHistoryStore.entries(), isEmpty);
  });

  test('formatViewedAt：同年 MM-dd HH:mm，跨年带年份', () {
    final now = DateTime(2026, 11, 13, 10, 8);
    expect(
      formatViewedAt(DateTime(2026, 3, 4, 8, 5), now: now),
      '03-04 08:05',
    );
    expect(
      formatViewedAt(DateTime(2025, 12, 31, 23, 59), now: now),
      '2025-12-31 23:59',
    );
  });
}
