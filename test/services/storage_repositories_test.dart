import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/storage/book_detail_cache_repository.dart';
import 'package:zlibx/services/storage/download_history_repository.dart';
import 'package:zlibx/services/storage/favorites_repository.dart';
import 'package:zlibx/services/storage/server_history_repository.dart';
import 'package:zlibx/services/storage/settings_repository.dart';
import 'package:zlibx/services/storage/storage_keys.dart';
import 'package:zlibx/services/storage_service.dart';

/// P1-4 split coverage: the per-domain repositories behind the
/// StorageService facade, driven directly (not through the facade),
/// so a regression in a moved method is caught at the place it now
/// lives. Same Hive setup as storage_service_test.dart.
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('storage_repositories');
    Hive.init(tempDir.path);
    await Hive.openBox(HiveService.settingsBoxName);
    await Hive.openBox(HiveService.libraryBoxName);
  });

  setUp(() async {
    await Hive.box(HiveService.settingsBoxName).clear();
    await Hive.box(HiveService.libraryBoxName).clear();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  group('FavoritesRepository', () {
    test('legacy migration merges into the account key, then runs once',
        () async {
      final repo = FavoritesRepository();
      final library = Hive.box(HiveService.libraryBoxName);
      await library.put(kFavoritesKey, ['1', '2']);
      await library.put(favoritesKeyFor('acct-a'), ['2', '3']);

      await repo.migrateLegacyFavoritesFor('acct-a');

      expect(
        repo.getFavoritesSyncForAccount('acct-a'),
        ['2', '3', '1'],
      );
      expect(library.containsKey(kFavoritesKey), isFalse);

      // Second run is a no-op (legacy key gone).
      await repo.migrateLegacyFavoritesFor('acct-a');
      expect(
        repo.getFavoritesSyncForAccount('acct-a'),
        ['2', '3', '1'],
      );
    });

    test('corrupt favorites entry reads as empty', () async {
      final repo = FavoritesRepository();
      await Hive.box(HiveService.libraryBoxName)
          .put(favoritesKeyFor('acct-a'), 'junk');
      expect(repo.getFavoritesSyncForAccount('acct-a'), isEmpty);
    });

    test('key helpers keep the frozen on-device names', () {
      expect(favoritesKeyFor('123'), 'favorite_books_123');
      expect(
        serverDownloadHistoryKeyFor('123'),
        'server_download_history_123',
      );
      expect(StorageService.favoritesKeyFor('123'), 'favorite_books_123');
      expect(
        StorageService.serverDownloadHistoryKeyFor('123'),
        'server_download_history_123',
      );
      expect(StorageService.libraryMigratedFlag, 'library_migrated_v1');
    });
  });

  group('DownloadHistoryRepository', () {
    test('add / get / remove round-trip keeps insertion order', () async {
      final repo = DownloadHistoryRepository();
      await repo.addToDownloadHistory('1', 'One', 'A', '/one.epub');
      await repo.addToDownloadHistory(
        '2',
        'Two',
        'B',
        '/two.epub',
        source: 'zlibrary',
        customSubfolder: '科幻',
        realPath: '/real/two.epub',
      );

      final history = await repo.getDownloadHistory();
      expect(history.keys.toList(), ['1', '2']);
      expect(history['2']!['source'], 'zlibrary');
      expect(history['2']!['customSubfolder'], '科幻');
      expect(history['2']!['realPath'], '/real/two.epub');
      expect(await repo.getDownloadedFilePath('1'), '/one.epub');

      await repo.updateDownloadHistoryLocation(
        '1',
        '/one-new.epub',
        realPath: '/real/one.epub',
      );
      expect(await repo.getDownloadedFilePath('1'), '/one-new.epub');
      expect(
        (await repo.getDownloadHistory())['1']!['realPath'],
        '/real/one.epub',
      );

      await repo.removeFromDownloadHistory('1');
      expect((await repo.getDownloadHistory()).keys, ['2']);
    });

    test('concurrent adds both survive (serialized write queue)', () async {
      final repo = DownloadHistoryRepository();
      await Future.wait([
        repo.addToDownloadHistory('1', 'One', 'A', '/one.epub'),
        repo.addToDownloadHistory('2', 'Two', 'B', '/two.epub'),
      ]);
      expect(
        (await repo.getDownloadHistory()).keys,
        containsAll(['1', '2']),
      );
    });
  });

  group('ServerHistoryRepository', () {
    test('server history round-trips and re-sorts newest first', () async {
      final repo = ServerHistoryRepository();
      await repo.saveServerDownloadHistoryForAccount('acct-a', [
        Book(
          id: 1,
          title: 'old',
          downloadedAt: DateTime.utc(2026, 11, 9),
        ),
        Book(
          id: 2,
          title: 'new',
          downloadedAt: DateTime.utc(2026, 11, 10),
        ),
      ]);
      final cached = repo.getServerDownloadHistorySyncForAccount('acct-a');
      expect(cached.map((b) => b.id), [2, 1]);
    });

    test('empty save never wipes a good cache', () async {
      final repo = ServerHistoryRepository();
      await repo.saveServerDownloadHistoryForAccount('acct-a', [
        Book(id: 1, title: 'one'),
      ]);
      await repo.saveServerDownloadHistoryForAccount('acct-a', []);
      expect(
        repo.getServerDownloadHistorySyncForAccount('acct-a'),
        hasLength(1),
      );
    });

    test('metadata merge keeps both concurrent additions', () async {
      final repo = ServerHistoryRepository();
      Book meta(int id) => Book(
        id: id,
        title: '书$id',
        author: '作者$id',
        cover: 'https://cover.example/$id.jpg',
        extension: 'epub',
        filesize: 1000 + id,
        filesizeString: '1.0 KB',
      );
      await Future.wait([
        repo.mergeDownloadedBookMetadata({7: meta(7)}),
        repo.mergeDownloadedBookMetadata({8: meta(8)}),
      ]);
      final cached = repo.getDownloadedBookMetadataSync();
      expect(cached.keys, containsAll([7, 8]));
      expect(cached[7]!.author, '作者7');
    });
  });

  group('BookDetailCacheRepository', () {
    test('extras merge/get round-trip', () async {
      final repo = BookDetailCacheRepository();
      const path = '/book/hash42/书.html';
      expect(repo.getBookDetailExtrasSync(path), isNull);
      await repo.mergeBookDetailExtras(path, {'volume': '第一卷'});
      final entry = repo.getBookDetailExtrasSync(path);
      expect(entry?['volume'], '第一卷');
      expect(entry?['fetchedAt'], isA<int>());
    });

    test('detail cache expires after the 7-day TTL', () async {
      final repo = BookDetailCacheRepository();
      await repo.putBookDetailCache('42', {'title': '书'});
      expect((await repo.getBookDetailCache('42'))?['title'], '书');

      final library = Hive.box(HiveService.libraryBoxName);
      final raw = Map<String, dynamic>.from(
        library.get('${kBookDetailCachePrefix}42') as Map,
      );
      raw['fetchedAt'] = DateTime.now()
          .subtract(const Duration(days: 8))
          .millisecondsSinceEpoch;
      await library.put('${kBookDetailCachePrefix}42', raw);
      expect(await repo.getBookDetailCache('42'), isNull);
    });

    test('eapi hash resolve stores only a changed hash', () async {
      final repo = BookDetailCacheRepository();
      await repo.putResolvedEapiHash('42', 'short', 'short');
      expect(await repo.getResolvedEapiHash('42', 'short'), isNull);
      await repo.putResolvedEapiHash('42', 'short', 'fulllonghash');
      expect(
        await repo.getResolvedEapiHash('42', 'short'),
        'fulllonghash',
      );
    });
  });

  group('SettingsRepository', () {
    test('theme mode and download path round-trip', () async {
      final repo = SettingsRepository();
      expect(await repo.getThemeMode(), 0);
      await repo.setThemeMode(2);
      expect(await repo.getThemeMode(), 2);
      expect(await repo.getDownloadPath(), isNull);
      await repo.setDownloadPath('/sdcard/Download');
      expect(await repo.getDownloadPath(), '/sdcard/Download');
    });
  });
}
