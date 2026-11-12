import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/storage_service.dart';

/// The server download-history cache (`server_download_history_<accountId>`)
/// is what makes the second open of the download history paint instantly: the notifier shows the last known list
/// first, then refreshes silently. These tests drive the
/// explicit-account entry points so they do not need a signed-in
/// account (secure storage is unavailable in tests); the no-account
/// behavior of the resolving methods is covered separately below.
/// Same Hive setup as favorites_migration_test.dart.
void main() {
  late Directory tempDir;
  late StorageService storage;
  late Box box;

  setUpAll(() async {
    tempDir =
        await Directory.systemTemp.createTemp('server_history_cache');
    Hive.init(tempDir.path);
    await Hive.openBox(HiveService.settingsBoxName);
    // AuthStorage.getCredentials() touches the auth box while
    // resolving the account id; open it so that path fails closed
    // (no stored credentials) instead of on a missing box.
    await Hive.openBox(HiveService.authBoxName);
  });

  setUp(() async {
    await Hive.box(HiveService.settingsBoxName).clear();
    await Hive.box(HiveService.authBoxName).clear();
    storage = StorageService();
    box = Hive.box(HiveService.settingsBoxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  Book book({
    required int id,
    required String title,
    DateTime? downloadedAt,
  }) {
    return Book(
      id: id,
      title: title,
      hash: 'hash$id',
      href: '/book/hash$id/$title.html',
      author: 'Author $id',
      cover: 'https://example.com/cover$id.jpg',
      extension: 'epub',
      filesize: 1000 + id,
      filesizeString: '1.0 KB',
      year: 2020 + id,
      downloadedAt: downloadedAt,
    );
  }

  void expectSameBook(Book actual, Book expected) {
    expect(actual.id, expected.id);
    expect(actual.title, expected.title);
    expect(actual.hash, expected.hash);
    expect(actual.href, expected.href);
    expect(actual.author, expected.author);
    expect(actual.cover, expected.cover);
    expect(actual.extension, expected.extension);
    expect(actual.filesize, expected.filesize);
    expect(actual.filesizeString, expected.filesizeString);
    expect(actual.year, expected.year);
    expect(actual.downloadedAt, expected.downloadedAt);
  }

  test('per-account key format', () {
    expect(
      StorageService.serverDownloadHistoryKeyFor('123'),
      'server_download_history_123',
    );
  });

  test('round-trip preserves every cached field', () async {
    final books = [
      book(id: 1, title: 'one', downloadedAt: DateTime.utc(2026, 11, 10)),
      book(id: 2, title: 'two', downloadedAt: DateTime.utc(2026, 11, 9)),
    ];
    await storage.saveServerDownloadHistoryForAccount('acct-a', books);

    final read =
        storage.getServerDownloadHistorySyncForAccount('acct-a');
    expect(read.length, 2);
    expectSameBook(read[0], books[0]);
    expectSameBook(read[1], books[1]);
  });

  test('read re-sorts by downloadedAt desc', () async {
    // Stored oldest-first (not display order): the read still paints
    // newest first.
    final books = [
      book(id: 1, title: 'old', downloadedAt: DateTime.utc(2026, 11, 9)),
      book(id: 2, title: 'new', downloadedAt: DateTime.utc(2026, 11, 10)),
    ];
    await storage.saveServerDownloadHistoryForAccount('acct-a', books);

    final read =
        storage.getServerDownloadHistorySyncForAccount('acct-a');
    expect(read.map((b) => b.id), [2, 1]);
  });

  test('saving an empty list never overwrites a good cache', () async {
    final books = [
      book(id: 1, title: 'one', downloadedAt: DateTime.utc(2026, 11, 10)),
    ];
    await storage.saveServerDownloadHistoryForAccount('acct-a', books);
    await storage.saveServerDownloadHistoryForAccount('acct-a', []);

    final read =
        storage.getServerDownloadHistorySyncForAccount('acct-a');
    expect(read.length, 1);
    expect(read[0].id, 1);
  });

  test('the other account starts empty', () async {
    final books = [
      book(id: 1, title: 'one', downloadedAt: DateTime.utc(2026, 11, 10)),
    ];
    await storage.saveServerDownloadHistoryForAccount('acct-a', books);

    expect(
      storage.getServerDownloadHistorySyncForAccount('acct-b'),
      isEmpty,
    );
  });

  test('a corrupt entry reads as empty instead of throwing', () async {
    await box.put(
      StorageService.serverDownloadHistoryKeyFor('acct-a'),
      'not-json{',
    );

    expect(
      storage.getServerDownloadHistorySyncForAccount('acct-a'),
      isEmpty,
    );
  });

  test('a non-list entry reads as empty instead of throwing', () async {
    await box.put(
      StorageService.serverDownloadHistoryKeyFor('acct-a'),
      '{"id": 1}',
    );

    expect(
      storage.getServerDownloadHistorySyncForAccount('acct-a'),
      isEmpty,
    );
  });

  test('signed-out reads see nothing instead of throwing', () async {
    final books = [
      book(id: 1, title: 'one', downloadedAt: DateTime.utc(2026, 11, 10)),
    ];
    await storage.saveServerDownloadHistoryForAccount('acct-a', books);

    expect(await storage.getServerDownloadHistory(), isEmpty);
  });

  test('signed-out writes are a no-op instead of throwing', () async {
    final books = [
      book(id: 1, title: 'one', downloadedAt: DateTime.utc(2026, 11, 10)),
    ];
    await storage.saveServerDownloadHistory(books);

    expect(
      box.containsKey(StorageService.serverDownloadHistoryKeyFor('')),
      isFalse,
    );
    expect(box.isEmpty, isTrue);
  });
}
