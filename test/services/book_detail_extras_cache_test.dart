import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/storage_service.dart';

/// The book-detail extras cache (`book_detail_extras`): the seven
/// parsed detail-page fields per page path, stamped with `fetchedAt`.
/// It is what lets a repeat open of the same book skip the hundreds-
/// of-KB HTML page entirely (7-day freshness window lives in the
/// provider). Same Hive setup as server_download_history_cache_test.
void main() {
  late Directory tempDir;
  late StorageService storage;
  late Box box;

  setUpAll(() async {
    tempDir =
        await Directory.systemTemp.createTemp('book_detail_extras_cache');
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

  Map<String, dynamic> fields({String volume = '第一卷'}) => {
        'volume': volume,
        'isbn10': '0000000000',
        'isbn13': '9780000000002',
        'ipfsCid': 'cid-1',
        'ipfsCidBlake2b': 'cid-blake-1',
        'ratingInterest': '3.0',
        'ratingQuality': '5.0',
      };

  test('merge stamps fetchedAt and the read returns all seven fields',
      () async {
    await storage.mergeBookDetailExtras('/book/h1/合成书.html', fields());

    final cached = storage.getBookDetailExtrasSync('/book/h1/合成书.html');
    expect(cached, isNotNull);
    expect(cached!['volume'], '第一卷');
    expect(cached['isbn13'], '9780000000002');
    expect(cached['ipfsCid'], 'cid-1');
    expect(cached['ipfsCidBlake2b'], 'cid-blake-1');
    expect(cached['ratingInterest'], '3.0');
    expect(cached['ratingQuality'], '5.0');
    expect(cached['fetchedAt'], isA<int>());
  });

  test('merge is incremental per key and fresh values overwrite', () async {
    await storage.mergeBookDetailExtras('/book/h1/a.html', fields());
    await storage.mergeBookDetailExtras('/book/h2/b.html', fields(volume: '第二卷'));
    await storage.mergeBookDetailExtras('/book/h1/a.html', fields(volume: '新版卷'));

    expect(
      storage.getBookDetailExtrasSync('/book/h1/a.html')!['volume'],
      '新版卷',
    );
    expect(
      storage.getBookDetailExtrasSync('/book/h2/b.html')!['volume'],
      '第二卷',
    );
  });

  test('empty path or empty fields are no-ops', () async {
    await storage.mergeBookDetailExtras('', fields());
    await storage.mergeBookDetailExtras('/book/h1/a.html', const {});

    expect(box.get('book_detail_extras'), isNull);
  });

  test('a corrupt blob reads as null and a later merge repairs it',
      () async {
    await box.put('book_detail_extras', 'not-json{');
    expect(storage.getBookDetailExtrasSync('/book/h1/a.html'), isNull);

    await storage.mergeBookDetailExtras('/book/h1/a.html', fields());
    expect(
      storage.getBookDetailExtrasSync('/book/h1/a.html')!['volume'],
      '第一卷',
    );
  });

  test('a missing key reads as null', () async {
    await storage.mergeBookDetailExtras('/book/h1/a.html', fields());
    expect(storage.getBookDetailExtrasSync('/book/h2/other.html'), isNull);
  });
}
