import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/storage_service.dart';

/// settings → library 迁移（审查 A1）与下载历史逐条键（审查 A2）的
/// 契约：旧数据升级、全新安装、重跑等价（中途被杀的恢复路径）、
/// 提前写不被旧值回滚、逐条历史的顺序/删除/坏条目语义。
Directory? _dir;

Map<String, dynamic> _entry(String title) => {
  'title': title,
  'author': '作者',
  'filePath': '/sdcard/Books/$title.epub',
  'cover': null,
  'extension': 'epub',
  'downloadTime': '2026-11-20T00:00:00.000',
};

void main() {
  setUpAll(() async {
    _dir = await Directory.systemTemp.createTemp('library_migration');
    Hive.init(_dir!.path);
  });

  setUp(() async {
    await Hive.openBox(HiveService.settingsBoxName);
    await Hive.openBox(HiveService.libraryBoxName);
    await HiveService.settingsBox.clear();
    await HiveService.libraryBox.clear();
  });

  tearDown(() async {
    // Hive 持有句柄，Windows 上必须先关库再删目录。
    await Hive.close();
  });

  tearDownAll(() async {
    await _dir?.delete(recursive: true);
  });

  test('旧数据升级：业务键搬进 library，整表历史转逐条，偏好留在 settings', () async {
    final settings = HiveService.settingsBox;
    await settings.put('favorite_books_acct-1', ['a', 'b']);
    await settings.put('download_history', jsonEncode({'7': _entry('七'), '8': _entry('八')}));
    await settings.put('book_detail_extras', jsonEncode({'/book/x/y.html': {'volume': '卷一'}}));
    await settings.put('server_download_history_acct-1', '[]');
    await settings.put('theme_mode', 1); // 偏好：不许被搬走

    await StorageService.migrateSettingsToLibrary();

    expect(settings.get(StorageService.libraryMigratedFlag), true);
    expect(settings.containsKey('favorite_books_acct-1'), isFalse);
    expect(settings.containsKey('download_history'), isFalse);
    expect(settings.containsKey('book_detail_extras'), isFalse);
    expect(settings.containsKey('server_download_history_acct-1'), isFalse);
    expect(settings.get('theme_mode'), 1);

    final library = HiveService.libraryBox;
    expect(library.get('favorite_books_acct-1'), ['a', 'b']);
    expect(library.get('dl_order'), ['7', '8']);
    expect((library.get('dl:7') as Map)['title'], '七');
    expect(library.get('book_detail_extras'), isA<String>());

    // 读路径走新结构：顺序与旧整表一致。
    final storage = StorageService();
    final history = await storage.getDownloadHistory();
    expect(history.keys.toList(), ['7', '8']);
    expect(await storage.getDownloadedFilePath('8'), '/sdcard/Books/八.epub');
    expect(storage.getFavoritesSyncForAccount('acct-1'), ['a', 'b']);
    expect(
      storage.getBookDetailExtrasSync('/book/x/y.html'),
      containsPair('volume', '卷一'),
    );
  });

  test('全新安装：无旧键，迁移只落标志，读路径全空不抛', () async {
    await StorageService.migrateSettingsToLibrary();
    expect(
      HiveService.settingsBox.get(StorageService.libraryMigratedFlag),
      true,
    );
    final storage = StorageService();
    expect(await storage.getDownloadHistory(), isEmpty);
    expect(storage.getFavoritesSyncForAccount('acct-1'), isEmpty);
    expect(storage.getBookDetailExtrasSync('/book/x/y.html'), isNull);
  });

  test('重跑等价：标志在直接返回；标志丢了也不覆盖 library 里的新值', () async {
    final settings = HiveService.settingsBox;
    final library = HiveService.libraryBox;
    await settings.put('favorite_books_acct-1', ['old']);
    await StorageService.migrateSettingsToLibrary();
    expect(library.get('favorite_books_acct-1'), ['old']);

    // 第二次：标志在，纯 no-op（library 里用户已改的新值不动）。
    await library.put('favorite_books_acct-1', ['new']);
    await StorageService.migrateSettingsToLibrary();
    expect(library.get('favorite_books_acct-1'), ['new']);

    // 模拟"迁移中途被杀"：标志没写成、旧键还在 settings、新写已进
    // library——重跑必须保留 library 的新值并清掉 settings 旧键。
    await settings.delete(StorageService.libraryMigratedFlag);
    await settings.put('favorite_books_acct-1', ['old']);
    await StorageService.migrateSettingsToLibrary();
    expect(library.get('favorite_books_acct-1'), ['new']);
    expect(settings.containsKey('favorite_books_acct-1'), isFalse);
    expect(settings.get(StorageService.libraryMigratedFlag), true);
  });

  test('旧整表历史损坏：原值进隔离键，不挡其他键迁移', () async {
    final settings = HiveService.settingsBox;
    await settings.put('download_history', '{not json');
    await settings.put('favorite_books_acct-1', ['a']);

    await StorageService.migrateSettingsToLibrary();

    final library = HiveService.libraryBox;
    expect(library.get('download_history_corrupt'), '{not json');
    expect(library.containsKey('download_history'), isFalse);
    expect(library.get('favorite_books_acct-1'), ['a']);
    expect(await StorageService().getDownloadHistory(), isEmpty);
  });

  group('A2 逐条历史语义', () {
    test('增/重加/删：重加保持原位，删除同步顺序表', () async {
      final storage = StorageService();
      await storage.addToDownloadHistory('1', '一', null, '/p/1.epub');
      await storage.addToDownloadHistory('2', '二', null, '/p/2.epub');
      // 重加已存在的 id：位置不变（旧整表 Map 的同语义）。
      await storage.addToDownloadHistory('1', '一改', null, '/p/1b.epub');
      var history = await storage.getDownloadHistory();
      expect(history.keys.toList(), ['1', '2']);
      expect(history['1']['title'], '一改');
      expect(await storage.getDownloadedFilePath('1'), '/p/1b.epub');

      await storage.removeFromDownloadHistory('2');
      history = await storage.getDownloadHistory();
      expect(history.keys.toList(), ['1']);
      expect(await storage.getDownloadedFilePath('2'), isNull);
    });

    test('坏条目只丢自己：非 Map 值跳过且不抛', () async {
      final library = HiveService.libraryBox;
      await library.put('dl:1', _entry('一'));
      await library.put('dl:2', 'junk');
      await library.put('dl_order', ['1', '2']);
      final history = await StorageService().getDownloadHistory();
      expect(history.keys.toList(), ['1']);
    });
  });
}
