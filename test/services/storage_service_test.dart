import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/storage_service.dart';

/// The local download-history blob (`download_history`) and the
/// whole-blob JSON caches it shares the write queue with:
/// concurrent read-modify-write calls for the same key must not lose
/// an entry (P1-1), and a corrupt history blob must read as empty
/// instead of crashing the caller (P1-2). Same Hive setup as
/// book_detail_extras_cache_test.dart.
void main() {
  late Directory tempDir;
  late StorageService storage;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('storage_service');
    Hive.init(tempDir.path);
    await Hive.openBox(HiveService.settingsBoxName);
    await Hive.openBox(HiveService.libraryBoxName);
  });

  setUp(() async {
    await Hive.box(HiveService.settingsBoxName).clear();
    await Hive.box(HiveService.libraryBoxName).clear();
    storage = StorageService();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  Book meta({required int id}) => Book(
        id: id,
        title: '元数据书$id',
        author: '作者$id',
        cover: 'https://cover.example/$id.jpg',
        extension: 'epub',
        filesize: 1000 + id,
        filesizeString: '1.0 KB',
      );

  test('concurrent addToDownloadHistory calls both survive', () async {
    await Future.wait([
      storage.addToDownloadHistory(
        '1',
        'Book One',
        'Author A',
        '/path/one.epub',
      ),
      storage.addToDownloadHistory(
        '2',
        'Book Two',
        'Author B',
        '/path/two.epub',
      ),
    ]);

    final history = await storage.getDownloadHistory();
    expect(history.keys, containsAll(['1', '2']));
    expect(history['1']!['title'], 'Book One');
    expect(history['2']!['title'], 'Book Two');
  });

  test('concurrent mergeDownloadedBookMetadata calls both survive',
      () async {
    await Future.wait([
      storage.mergeDownloadedBookMetadata({7: meta(id: 7)}),
      storage.mergeDownloadedBookMetadata({8: meta(id: 8)}),
    ]);

    final cached = storage.getDownloadedBookMetadataSync();
    expect(cached.keys, containsAll([7, 8]));
    expect(cached[7]!.author, '作者7');
    expect(cached[8]!.author, '作者8');
  });

  // A2（2026-11-20）后历史是逐条键：损坏隔离从"整表"缩到"单条"。
  // 旧整表 JSON 的损坏路径由迁移接管（library_migration_test 钉）。
  test('per-entry corrupt: a junk value is skipped, the rest survives',
      () async {
    final library = Hive.box(HiveService.libraryBoxName);
    await library.put('dl:1', {
      'title': 'Book One',
      'filePath': '/one.epub',
      'downloadTime': '2026-11-20T00:00:00.000',
    });
    await library.put('dl:2', 'junk');
    await library.put('dl_order', ['1', '2']);

    final history = await storage.getDownloadHistory();
    expect(history.keys, ['1']);
    expect(await storage.getDownloadedFilePath('2'), isNull);
    expect(await storage.getDownloadedFilePath('1'), '/one.epub');
  });

  test('per-entry corrupt: a non-String non-Map value is skipped too',
      () async {
    final library = Hive.box(HiveService.libraryBoxName);
    await library.put('dl:3', 42);
    await library.put('dl_order', ['3']);
    expect(await storage.getDownloadHistory(), isEmpty);
  });

  test('missing order list: entries are picked up by key, none lost',
      () async {
    final library = Hive.box(HiveService.libraryBoxName);
    await library.put('dl:5', {'title': '五', 'filePath': '/5.epub'});
    await library.put('dl:6', {'title': '六', 'filePath': '/6.epub'});

    final history = await storage.getDownloadHistory();
    expect(history.keys.toSet(), {'5', '6'});
  });

  test('a non-Map entry inside the history map is skipped', () async {
    final library = Hive.box(HiveService.libraryBoxName);
    await library.put('dl:1', {
      'title': 'Book One',
      'filePath': '/one.epub',
    });
    await library.put('dl:2', 'not a map');
    await library.put('dl_order', ['1', '2']);

    final history = await storage.getDownloadHistory();
    expect(history.keys, ['1']);
    expect(history['1']!['title'], 'Book One');
    // The skipped entry does not break the file-path lookup.
    expect(await storage.getDownloadedFilePath('2'), isNull);
    expect(await storage.getDownloadedFilePath('1'), '/one.epub');
  });
}
