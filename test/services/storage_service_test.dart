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
  late Box box;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('storage_service');
    Hive.init(tempDir.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  setUp(() async {
    await Hive.box(HiveService.settingsBoxName).clear();
    storage = StorageService();
    box = Hive.box(HiveService.settingsBoxName);
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

  test('getDownloadHistory with illegal JSON returns {} and does not throw',
      () async {
    await box.put('download_history', '{not valid json');

    final history = await storage.getDownloadHistory();
    expect(history, isEmpty);
    // The corrupt value is quarantined, not silently lost.
    expect(box.get('download_history_corrupt'), '{not valid json');
  });

  test('getDownloadHistory with a non-String value returns {} and does not throw',
      () async {
    await box.put('download_history', 42);

    final history = await storage.getDownloadHistory();
    expect(history, isEmpty);
    expect(box.get('download_history_corrupt'), 42);
  });

  test('getDownloadHistory with a top-level list returns {} and does not throw',
      () async {
    await box.put('download_history', '["a", "b"]');

    final history = await storage.getDownloadHistory();
    expect(history, isEmpty);
    expect(box.get('download_history_corrupt'), '["a", "b"]');
  });

  test('a non-Map entry inside the history map is skipped', () async {
    await box.put(
      'download_history',
      '{"1": {"title": "Book One", "filePath": "/one.epub"}, '
      '"2": "not a map"}',
    );

    final history = await storage.getDownloadHistory();
    expect(history.keys, ['1']);
    expect(history['1']!['title'], 'Book One');
    // The skipped entry does not break the file-path lookup.
    expect(await storage.getDownloadedFilePath('2'), isNull);
    expect(await storage.getDownloadedFilePath('1'), '/one.epub');
  });
}
