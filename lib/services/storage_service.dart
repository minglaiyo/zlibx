import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import '../utils/app_log.dart';
import 'auth_storage.dart';
import 'hive_service.dart';

/// Riverpod provider for StorageService (singleton)
final storageServiceProvider = Provider<StorageService>((ref) {
  return StorageService();
});

class StorageService {
  /// Legacy shared favorites key: every account read and wrote the
  /// same list. Kept only so the one-time migration can find it — no
  /// favorites read/write uses it anymore (see [favoritesKeyFor]).
  static const String _keyFavorites = 'favorite_books';
  // _keyDownloads was removed with the dead saveDownloadedBook() method:
  // it stored `bookInfo.toString()` (a Dart debug string, not JSON, not
  // parseable) and had no callers — download history lives in
  // _keyDownloadHistory below.
  static const String _keyThemeMode = 'theme_mode';
  static const String _keyDownloadPath = 'download_path';
  static const String _keyDownloadHistory = 'download_history';

  /// Per-account server download-history cache key:
  /// `server_download_history_<accountId>`. Deliberately NOT
  /// [_keyDownloadHistory] above — that key is the LOCAL file-download
  /// map ({bookId: {title, author, filePath, ...}}), a different thing.
  /// Same account-scoping rule as [favoritesKeyFor]: the account id is
  /// the Z-Library user id, so each account reads only its own cached
  /// history and a different account starts with no cache.
  static const String _keyServerDownloadHistory =
      'server_download_history';

  /// Per-account server download-history cache key (see above).
  static String serverDownloadHistoryKeyFor(String accountId) =>
      '${_keyServerDownloadHistory}_$accountId';

  /// Per-account favorites key: `favorite_books_<accountId>`.
  /// The account id is the Z-Library user id (a String — see User.id),
  /// the same value stored as the `remix_userid` credential, so the
  /// key follows the signed-in account and never a display name or
  /// email. Each account reads and writes only its own key, which is
  /// what keeps the local hearts in sync with the account-scoped
  /// server list after a switch.
  static String favoritesKeyFor(String accountId) =>
      '${_keyFavorites}_$accountId';

  /// The signed-in account's id, or null when signed out or when the
  /// stored credentials cannot be read (secure storage unavailable).
  /// A null here means "no account to scope to": reads see nothing and
  /// writes refuse, rather than touching the shared legacy key.
  Future<String?> _currentAccountId() async {
    try {
      final userId = (await AuthStorage().getCredentials())['userId'];
      return (userId == null || userId.isEmpty) ? null : userId;
    } catch (error) {
      AppLog.report('[storage] cannot resolve account id', tag: 'storage_service');
      return null;
    }
  }

  /// Read one favorites list from Hive, tolerating a corrupt entry
  /// (wrong type, non-string ids) as empty instead of crashing the
  /// caller. A corrupt legacy entry must not block the migration.
  List<String> _readFavoritesForKey(String key) {
    final data = HiveService.settingsBox.get(key);
    if (data is! List) return [];
    try {
      return List<String>.from(data);
    } catch (error) {
      AppLog.report('[storage] ignoring corrupt favorites entry', tag: 'storage_service');
      return [];
    }
  }

  /// One-time migration of the legacy shared favorites list to the
  /// account signed in right now. Runs lazily at the start of every
  /// favorites operation (and once eagerly at startup from main):
  /// - No signed-in account: does nothing and leaves the legacy key
  ///   in place, so a later login can still migrate it. Nothing is
  ///   ever migrated to an empty account id.
  /// - Legacy key absent or empty: nothing to do.
  /// - Target key already has favorites: merged (target order first,
  ///   then legacy ids not already present) — the old list never
  ///   overwrites the account's own list.
  /// - Afterwards the legacy key is deleted: that deletion is what
  ///   makes the migration run exactly once. A second call finds no
  ///   legacy key and returns immediately.
  /// Never throws: a storage failure leaves the legacy key untouched
  /// so the next call retries instead of losing data.
  Future<void> migrateLegacyFavorites() async {
    final accountId = await _currentAccountId();
    if (accountId == null) return;
    await migrateLegacyFavoritesFor(accountId);
  }

  /// Same migration for an explicit account id. Public (instead of
  /// private) so tests can drive it without a signed-in account.
  Future<void> migrateLegacyFavoritesFor(String accountId) async {
    if (accountId.isEmpty) return;
    try {
      final box = HiveService.settingsBox;
      if (!box.containsKey(_keyFavorites)) return;
      final legacy = _readFavoritesForKey(_keyFavorites);
      if (legacy.isNotEmpty) {
        final targetKey = favoritesKeyFor(accountId);
        final merged = _readFavoritesForKey(targetKey);
        for (final id in legacy) {
          if (!merged.contains(id)) merged.add(id);
        }
        await box.put(targetKey, merged);
      }
      await box.delete(_keyFavorites);
    } catch (error) {
      AppLog.report('[storage] favorites migration failed', tag: 'storage_service');
    }
  }

  /// Save favorite book IDs for the signed-in account. Throws
  /// [StateError] when signed out: there is no account key to write
  /// to, and silently dropping the write would lose the favorite.
  Future<void> saveFavorites(List<String> bookIds) async {
    final accountId = await _currentAccountId();
    if (accountId == null) {
      throw StateError('cannot save favorites: no signed-in account');
    }
    await migrateLegacyFavoritesFor(accountId);
    await HiveService.settingsBox.put(
      favoritesKeyFor(accountId),
      bookIds,
    );
  }

  /// Get favorite book IDs for the signed-in account ([] when signed
  /// out — a signed-out user has no account list to show).
  Future<List<String>> getFavorites() async {
    final accountId = await _currentAccountId();
    if (accountId == null) return [];
    await migrateLegacyFavoritesFor(accountId);
    return _readFavoritesForKey(favoritesKeyFor(accountId));
  }

  /// Synchronous read of one account's favorites, for callers that
  /// already know the account id. Prefer [getFavorites].
  List<String> getFavoritesSyncForAccount(String accountId) =>
      _readFavoritesForKey(favoritesKeyFor(accountId));

  /// Add a book to the signed-in account's favorites. Throws
  /// [StateError] when signed out (see [saveFavorites]).
  Future<void> addFavorite(String bookId) async {
    final accountId = await _currentAccountId();
    if (accountId == null) {
      throw StateError('cannot add favorite: no signed-in account');
    }
    await migrateLegacyFavoritesFor(accountId);
    final key = favoritesKeyFor(accountId);
    final favorites = _readFavoritesForKey(key);
    if (!favorites.contains(bookId)) {
      favorites.add(bookId);
      await HiveService.settingsBox.put(key, favorites);
    }
  }

  /// Remove a book from the signed-in account's favorites. Throws
  /// [StateError] when signed out (see [saveFavorites]).
  Future<void> removeFavorite(String bookId) async {
    final accountId = await _currentAccountId();
    if (accountId == null) {
      throw StateError('cannot remove favorite: no signed-in account');
    }
    await migrateLegacyFavoritesFor(accountId);
    final key = favoritesKeyFor(accountId);
    final favorites = _readFavoritesForKey(key);
    favorites.remove(bookId);
    await HiveService.settingsBox.put(key, favorites);
  }

  /// Check whether a book is in the signed-in account's favorites
  /// (false when signed out).
  Future<bool> isFavorite(String bookId) async {
    final accountId = await _currentAccountId();
    if (accountId == null) return false;
    await migrateLegacyFavoritesFor(accountId);
    final favorites = _readFavoritesForKey(favoritesKeyFor(accountId));
    return favorites.contains(bookId);
  }

  /// Get theme mode (0: system, 1: light, 2: dark)
  Future<int> getThemeMode() async {
    return HiveService.settingsBox.get(_keyThemeMode, defaultValue: 0) as int;
  }

  /// Set theme mode
  Future<void> setThemeMode(int mode) async {
    await HiveService.settingsBox.put(_keyThemeMode, mode);
  }

  /// Get download path
  Future<String?> getDownloadPath() async {
    return HiveService.settingsBox.get(_keyDownloadPath) as String?;
  }

  /// Set download path
  Future<void> setDownloadPath(String path) async {
    await HiveService.settingsBox.put(_keyDownloadPath, path);
  }

  // ===== Download History Methods =====
  
  /// Add book to download history
  /// Stores: {bookId: {title, author, filePath, cover, extension, downloadTime}}
  Future<void> addToDownloadHistory(
    String bookId, 
    String title, 
    String? author, 
    String filePath, 
    {String? cover, String? extension}
  ) async {
    final historyJson = HiveService.settingsBox.get(_keyDownloadHistory, defaultValue: '{}') as String;
    final history = Map<String, dynamic>.from(jsonDecode(historyJson));
    
    history[bookId] = {
      'title': title,
      'author': author,
      'filePath': filePath,
      'cover': cover,
      'extension': extension,
      'downloadTime': DateTime.now().toIso8601String(),
    };
    
    await HiveService.settingsBox.put(_keyDownloadHistory, jsonEncode(history));
  }

  /// Get all download history
  Future<Map<String, dynamic>> getDownloadHistory() async {
    final historyJson = HiveService.settingsBox.get(_keyDownloadHistory, defaultValue: '{}') as String;
    return Map<String, dynamic>.from(jsonDecode(historyJson));
  }

  /// Get downloaded file path for a book
  Future<String?> getDownloadedFilePath(String bookId) async {
    final history = await getDownloadHistory();
    if (history.containsKey(bookId)) {
      return history[bookId]['filePath'] as String?;
    }
    return null;
  }

  /// Remove book from download history
  Future<void> removeFromDownloadHistory(String bookId) async {
    final historyJson = HiveService.settingsBox.get(_keyDownloadHistory, defaultValue: '{}') as String;
    final history = Map<String, dynamic>.from(jsonDecode(historyJson));
    
    history.remove(bookId);
    
    await HiveService.settingsBox.put(_keyDownloadHistory, jsonEncode(history));
  }

  // ===== Server Download History Cache =====
  //
  // The `/users/downloads` list is slow to load from the network (every
  // page goes through the WebView solver while the mirror walls HTML
  // routes — first paint 5–8 s, full load 16–19 s, 2026-11-12). The
  // cache makes the second open paint instantly: the notifier shows
  // the last known list first, then refreshes silently in the
  // background and overwrites the cache with the fresh full list.
  // The cache is at most one open stale; there is no TTL or expiry.
  // All methods are best-effort and never throw: a storage failure
  // must not fail a background refresh, and a corrupt entry reads as
  // empty instead of crashing the caller.

  /// Save the final server download-history list for an explicit
  /// account. Public (instead of private) so tests can drive it
  /// without a signed-in account. Only non-empty lists are stored:
  /// an empty result must never wipe a good cache — a failed or
  /// partial load ends with an empty list too, and the stored list is
  /// the last known good one. (A genuinely emptied server history
  /// keeps showing its cached list until a non-empty load replaces
  /// it; that is the accepted trade-off.)
  Future<void> saveServerDownloadHistoryForAccount(
    String accountId,
    List<Book> books,
  ) async {
    if (accountId.isEmpty || books.isEmpty) return;
    try {
      final booksJson = jsonEncode([for (final book in books) book.toJson()]);
      await HiveService.settingsBox.put(
        serverDownloadHistoryKeyFor(accountId),
        booksJson,
      );
    } catch (error) {
      AppLog.report(
        '[storage] server history cache save failed',
        tag: 'storage_service',
      );
    }
  }

  /// Save the final server download-history list for the signed-in
  /// account. No-op when signed out (the cache is best-effort; a
  /// missing account must not throw out of a background refresh).
  Future<void> saveServerDownloadHistory(List<Book> books) async {
    final accountId = await _currentAccountId();
    if (accountId == null) return;
    await saveServerDownloadHistoryForAccount(accountId, books);
  }

  /// Synchronous read of one account's cached server download
  /// history, for callers that already know the account id (e.g. the
  /// notifier's build(), which must paint synchronously). A missing or
  /// corrupt entry reads as empty, never throws. The stored list is in
  /// display order (downloadedAt desc); re-sorted defensively on read
  /// so a hand-edited or older entry still paints in order.
  List<Book> getServerDownloadHistorySyncForAccount(String accountId) {
    if (accountId.isEmpty) return const <Book>[];
    final raw = HiveService.settingsBox.get(
      serverDownloadHistoryKeyFor(accountId),
    );
    if (raw is! String || raw.isEmpty) return const <Book>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <Book>[];
      final books = <Book>[];
      for (final entry in decoded) {
        if (entry is Map) {
          books.add(Book.fromJson(Map<String, dynamic>.from(entry)));
        }
      }
      books.sort(_downloadedAtDesc);
      return books;
    } catch (error) {
      AppLog.report(
        '[storage] ignoring corrupt server history cache',
        tag: 'storage_service',
      );
      return const <Book>[];
    }
  }

  /// Async read of the signed-in account's cached server download
  /// history ([] when signed out — a signed-out user has no account
  /// cache to show).
  Future<List<Book>> getServerDownloadHistory() async {
    final accountId = await _currentAccountId();
    if (accountId == null) return const <Book>[];
    return getServerDownloadHistorySyncForAccount(accountId);
  }

  /// downloadedAt descending, nulls last (a record without a stamp
  /// sorts after every stamped one).
  static int _downloadedAtDesc(Book a, Book b) {
    final aTime = a.downloadedAt;
    final bTime = b.downloadedAt;
    if (aTime == null && bTime == null) return 0;
    if (aTime == null) return 1;
    if (bTime == null) return -1;
    return bTime.compareTo(aTime);
  }
}
