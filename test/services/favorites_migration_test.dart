import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zlibx/services/hive_service.dart';
import 'package:zlibx/services/storage_service.dart';

/// Favorites are namespaced per account (`favorite_books_<accountId>`)
/// and the legacy shared 'favorite_books' list is migrated once to
/// the signed-in account. These tests drive the explicit-account
/// migration entry point so they do not need a signed-in account
/// (secure storage is unavailable in tests); the no-account behavior
/// of the resolving methods is covered separately below.
void main() {
  late Directory tempDir;
  late StorageService storage;
  late Box<dynamic> box;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('favorites_migration');
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

  test('per-account key format', () {
    expect(StorageService.favoritesKeyFor('123'), 'favorite_books_123');
  });

  test('migration moves the legacy list to the account key', () async {
    await box.put('favorite_books', ['1', '2']);
    await storage.migrateLegacyFavoritesFor('acct-a');

    expect(box.containsKey('favorite_books'), isFalse);
    expect(
      box.get(StorageService.favoritesKeyFor('acct-a')),
      ['1', '2'],
    );
  });

  test('migration is a no-op when the legacy key is absent', () async {
    await box.put(StorageService.favoritesKeyFor('acct-a'), ['9']);
    await storage.migrateLegacyFavoritesFor('acct-a');

    expect(box.get(StorageService.favoritesKeyFor('acct-a')), ['9']);
    expect(box.containsKey('favorite_books'), isFalse);
  });

  test('migration merges without overwriting the target list', () async {
    await box.put('favorite_books', ['2', '3']);
    await box.put(StorageService.favoritesKeyFor('acct-a'), ['1', '2']);
    await storage.migrateLegacyFavoritesFor('acct-a');

    expect(box.containsKey('favorite_books'), isFalse);
    expect(
      box.get(StorageService.favoritesKeyFor('acct-a')),
      ['1', '2', '3'],
    );
  });

  test('migration with an empty legacy list deletes the legacy key', () async {
    await box.put('favorite_books', <String>[]);
    await storage.migrateLegacyFavoritesFor('acct-a');

    expect(box.containsKey('favorite_books'), isFalse);
    expect(box.containsKey(StorageService.favoritesKeyFor('acct-a')), isFalse);
  });

  test('migration with an empty account id leaves the legacy key', () async {
    await box.put('favorite_books', ['1']);
    await storage.migrateLegacyFavoritesFor('');

    expect(box.get('favorite_books'), ['1']);
  });

  test('migration is idempotent', () async {
    await box.put('favorite_books', ['1', '2']);
    await storage.migrateLegacyFavoritesFor('acct-a');
    await storage.migrateLegacyFavoritesFor('acct-a');

    expect(box.containsKey('favorite_books'), isFalse);
    expect(
      box.get(StorageService.favoritesKeyFor('acct-a')),
      ['1', '2'],
    );
  });

  test('the other account starts empty after migration', () async {
    await box.put('favorite_books', ['1', '2']);
    await storage.migrateLegacyFavoritesFor('acct-a');

    expect(
      storage.getFavoritesSyncForAccount('acct-b'),
      isEmpty,
    );
  });

  test('signed-out reads see nothing instead of throwing', () async {
    await box.put('favorite_books', ['1']);
    expect(await storage.getFavorites(), isEmpty);
    expect(await storage.isFavorite('1'), isFalse);
    // The legacy list is untouched while signed out.
    expect(box.get('favorite_books'), ['1']);
  });

  test('signed-out writes refuse instead of touching the legacy key',
      () async {
    await box.put('favorite_books', ['1']);
    expect(() => storage.addFavorite('2'), throwsStateError);
    expect(() => storage.removeFavorite('1'), throwsStateError);
    expect(() => storage.saveFavorites(['2']), throwsStateError);
    expect(box.get('favorite_books'), ['1']);
  });
}
