import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/storage_service.dart';

/// The downloaded-book metadata cache (`downloaded_book_metadata`):
/// the five overlay fields per book id, seeded into every download-
/// history load so covers/authors paint on the first page and the
/// eapi pagination can be skipped when it covers every row id. Same
/// Hive setup as server_download_history_cache_test.dart.
void main() {
  late Directory tempDir;
  late StorageService storage;
  late Box<dynamic> box;

  setUpAll(() async {
    tempDir =
        await Directory.systemTemp.createTemp('downloaded_metadata_cache');
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

  Book meta({required int id, String author = '作者'}) => Book(
        id: id,
        title: '元数据书$id',
        author: author,
        cover: 'https://cover.example/$id.jpg',
        extension: 'epub',
        filesize: 1000 + id,
        filesizeString: '1.0 KB',
      );

  test('merge then read: the five overlay fields round-trip per id',
      () async {
    await storage.mergeDownloadedBookMetadata({
      7: meta(id: 7, author: '作者甲'),
      8: meta(id: 8, author: '作者乙'),
    });

    final cached = storage.getDownloadedBookMetadataSync();
    expect(cached.keys, containsAll([7, 8]));
    expect(cached[7]!.author, '作者甲');
    expect(cached[7]!.cover, 'https://cover.example/7.jpg');
    expect(cached[7]!.extension, 'epub');
    expect(cached[7]!.filesize, 1007);
    expect(cached[7]!.filesizeString, '1.0 KB');
    // id 是键、不在 JSON 里重复：读回来的书带正确 id（overlay 按 id
    // 对齐 dstats 记录）。
    expect(cached[8]!.id, 8);
  });

  test('merge is incremental: existing entries survive, new ones join',
      () async {
    await storage.mergeDownloadedBookMetadata({7: meta(id: 7)});
    await storage.mergeDownloadedBookMetadata({8: meta(id: 8)});

    final cached = storage.getDownloadedBookMetadataSync();
    expect(cached.keys, containsAll([7, 8]));
    expect(cached[7]!.author, '作者');
  });

  test('fresh values overwrite cached ones for the same id', () async {
    await storage.mergeDownloadedBookMetadata({
      7: meta(id: 7, author: '旧作者'),
    });
    await storage.mergeDownloadedBookMetadata({
      7: meta(id: 7, author: '新作者'),
    });

    expect(storage.getDownloadedBookMetadataSync()[7]!.author, '新作者');
  });

  test('an empty merge is a no-op (never wipes the cache)', () async {
    await storage.mergeDownloadedBookMetadata({7: meta(id: 7)});
    await storage.mergeDownloadedBookMetadata(const {});

    expect(storage.getDownloadedBookMetadataSync().keys, [7]);
  });

  test('a corrupt blob reads as empty and a later merge repairs it',
      () async {
    await box.put('downloaded_book_metadata', 'not-json{');
    expect(storage.getDownloadedBookMetadataSync(), isEmpty);

    await storage.mergeDownloadedBookMetadata({7: meta(id: 7)});
    expect(storage.getDownloadedBookMetadataSync()[7]!.author, '作者');
  });

  test('entries without a usable id are ignored on read', () async {
    await box.put(
      'downloaded_book_metadata',
      jsonEncode({
        '7': {'author': '作者甲'},
        'not-an-id': {'author': '坏条目'},
        '0': {'author': '零 id'},
      }),
    );

    final cached = storage.getDownloadedBookMetadataSync();
    expect(cached.keys, [7]);
  });

  test('the blob carries only the overlay fields', () async {
    await storage.mergeDownloadedBookMetadata({
      7: Book(
        id: 7,
        title: '整本书',
        href: '/book/x/整本书.html',
        downloadedAt: DateTime(2026, 11, 13),
        author: '作者甲',
        cover: 'https://cover.example/7.jpg',
        extension: 'epub',
      ),
    });

    final stored = jsonDecode(
      box.get('downloaded_book_metadata') as String,
    ) as Map;
    // id 是键；值里只有叠加五字段——title/href/downloadedAt 是 dstats
    // 行自己的事，不进这份缓存。
    expect(stored.keys, ['7']);
    expect((stored['7'] as Map).keys,
        ['author', 'cover', 'extension', 'filesize', 'filesizeString']);
  });
}
