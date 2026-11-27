import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import 'storage/book_detail_cache_repository.dart';
import 'storage/download_history_repository.dart';
import 'storage/favorites_repository.dart';
import 'storage/library_migration.dart';
import 'storage/server_history_repository.dart';
import 'storage/settings_repository.dart';
import 'storage/storage_keys.dart' as storage_keys;

/// Riverpod provider for StorageService (singleton)
final storageServiceProvider = Provider<StorageService>((ref) {
  return StorageService();
});

/// Thin facade over the per-domain repositories split out by P1-4
/// (`lib/services/storage/`): favorites, download history, server
/// history + metadata overlay, book-detail caches, and settings.
///
/// The public API is unchanged — same class, same constructor, same
/// method names, signatures, statics and Hive/settings key names —
/// so every existing call site (providers, screens, tests, including
/// the `_FakeStorage extends StorageService` test doubles) keeps
/// working without edits. All behavior lives in the repositories;
/// each method below is a one-line delegation.
class StorageService {
  final FavoritesRepository _favorites = FavoritesRepository();
  final DownloadHistoryRepository _downloadHistory =
      DownloadHistoryRepository();
  final ServerHistoryRepository _serverHistory = ServerHistoryRepository();
  final BookDetailCacheRepository _bookDetailCache =
      BookDetailCacheRepository();
  final SettingsRepository _settings = SettingsRepository();

  /// Per-account favorites key: `favorite_books_<accountId>`.
  /// See [favoritesKeyFor] in `storage/storage_keys.dart`.
  static String favoritesKeyFor(String accountId) =>
      storage_keys.favoritesKeyFor(accountId);

  /// Per-account server download-history cache key:
  /// `server_download_history_<accountId>`.
  static String serverDownloadHistoryKeyFor(String accountId) =>
      storage_keys.serverDownloadHistoryKeyFor(accountId);

  /// 迁移完成标志键（留在 settings：它本身就是偏好级的小键）。
  static const String libraryMigratedFlag =
      storage_keys.kLibraryMigratedFlag;

  /// settings → library one-time migration (review A1/A2).
  static Future<void> migrateSettingsToLibrary() =>
      LibraryMigration.migrateSettingsToLibrary();

  // ===== Favorites =====

  Future<void> migrateLegacyFavorites() => _favorites.migrateLegacyFavorites();

  Future<void> migrateLegacyFavoritesFor(String accountId) =>
      _favorites.migrateLegacyFavoritesFor(accountId);

  Future<void> saveFavorites(List<String> bookIds) =>
      _favorites.saveFavorites(bookIds);

  Future<List<String>> getFavorites() => _favorites.getFavorites();

  List<String> getFavoritesSyncForAccount(String accountId) =>
      _favorites.getFavoritesSyncForAccount(accountId);

  Future<void> addFavorite(String bookId) => _favorites.addFavorite(bookId);

  Future<void> removeFavorite(String bookId) =>
      _favorites.removeFavorite(bookId);

  Future<bool> isFavorite(String bookId) => _favorites.isFavorite(bookId);

  // ===== Settings (theme mode / download path) =====

  Future<int> getThemeMode() => _settings.getThemeMode();

  Future<void> setThemeMode(int mode) => _settings.setThemeMode(mode);

  Future<String?> getDownloadPath() => _settings.getDownloadPath();

  Future<void> setDownloadPath(String path) =>
      _settings.setDownloadPath(path);

  // ===== Local download history =====

  Future<Map<String, dynamic>> getDownloadHistory() =>
      _downloadHistory.getDownloadHistory();

  Future<String?> getDownloadedFilePath(String bookId) =>
      _downloadHistory.getDownloadedFilePath(bookId);

  Future<void> addToDownloadHistory(
    String bookId,
    String title,
    String? author,
    String filePath, {
    String? cover,
    String? extension,
    String? source,
    String? customSubfolder,
    String? realPath,
  }) => _downloadHistory.addToDownloadHistory(
    bookId,
    title,
    author,
    filePath,
    cover: cover,
    extension: extension,
    source: source,
    customSubfolder: customSubfolder,
    realPath: realPath,
  );

  Future<void> updateDownloadHistoryLocation(
    String bookId,
    String filePath, {
    String? realPath,
  }) => _downloadHistory.updateDownloadHistoryLocation(
    bookId,
    filePath,
    realPath: realPath,
  );

  Future<void> removeFromDownloadHistory(String bookId) =>
      _downloadHistory.removeFromDownloadHistory(bookId);

  // ===== Server download history cache =====

  Future<void> saveServerDownloadHistoryForAccount(
    String accountId,
    List<Book> books,
  ) => _serverHistory.saveServerDownloadHistoryForAccount(accountId, books);

  Future<void> saveServerDownloadHistory(List<Book> books) =>
      _serverHistory.saveServerDownloadHistory(books);

  List<Book> getServerDownloadHistorySyncForAccount(String accountId) =>
      _serverHistory.getServerDownloadHistorySyncForAccount(accountId);

  Future<List<Book>> getServerDownloadHistory() =>
      _serverHistory.getServerDownloadHistory();

  // ===== Downloaded-book metadata cache =====

  Map<int, Book> getDownloadedBookMetadataSync() =>
      _serverHistory.getDownloadedBookMetadataSync();

  Future<void> mergeDownloadedBookMetadata(Map<int, Book> additions) =>
      _serverHistory.mergeDownloadedBookMetadata(additions);

  // ===== Book-detail extras cache =====

  Map<String, dynamic>? getBookDetailExtrasSync(String pagePath) =>
      _bookDetailCache.getBookDetailExtrasSync(pagePath);

  Future<void> mergeBookDetailExtras(
    String pagePath,
    Map<String, dynamic> fields,
  ) => _bookDetailCache.mergeBookDetailExtras(pagePath, fields);

  // ===== Book-detail eapi cache =====

  Future<Map<String, dynamic>?> getBookDetailCache(String bookId) =>
      _bookDetailCache.getBookDetailCache(bookId);

  Future<void> putBookDetailCache(
    String bookId,
    Map<String, dynamic> json,
  ) => _bookDetailCache.putBookDetailCache(bookId, json);

  Future<String?> getResolvedEapiHash(String bookId, String hash) =>
      _bookDetailCache.getResolvedEapiHash(bookId, hash);

  Future<void> putResolvedEapiHash(
    String bookId,
    String hash,
    String resolved,
  ) => _bookDetailCache.putResolvedEapiHash(bookId, hash, resolved);
}
