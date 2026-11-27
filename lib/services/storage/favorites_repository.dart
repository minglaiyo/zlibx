import '../../utils/app_log.dart';
import '../hive_service.dart';
import 'storage_keys.dart';
import 'storage_shared.dart';

/// Per-account favorites, split out of `storage_service.dart` (P1-4).
/// Moved verbatim; no behavior change, no key-name change.
class FavoritesRepository {
  /// Read one favorites list from Hive, tolerating a corrupt entry
  /// (wrong type, non-string ids) as empty instead of crashing the
  /// caller. A corrupt legacy entry must not block the migration.
  List<String> _readFavoritesForKey(String key) {
    final data = readMovedValue(key);
    if (data is! List) return [];
    try {
      return List<String>.from(data);
    } catch (error) {
      AppLog.report(
        '[storage] ignoring corrupt favorites entry',
        tag: 'storage_service',
      );
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
    final accountId = await currentAccountId();
    if (accountId == null) return;
    await migrateLegacyFavoritesFor(accountId);
  }

  /// Same migration for an explicit account id. Public (instead of
  /// private) so tests can drive it without a signed-in account.
  Future<void> migrateLegacyFavoritesFor(String accountId) async {
    if (accountId.isEmpty) return;
    try {
      final box = await HiveService.libraryBoxAsync();
      if (!box.containsKey(kFavoritesKey)) return;
      final legacy = _readFavoritesForKey(kFavoritesKey);
      if (legacy.isNotEmpty) {
        final targetKey = favoritesKeyFor(accountId);
        final merged = _readFavoritesForKey(targetKey);
        for (final id in legacy) {
          if (!merged.contains(id)) merged.add(id);
        }
        await box.put(targetKey, merged);
      }
      await box.delete(kFavoritesKey);
    } catch (error) {
      AppLog.report(
        '[storage] favorites migration failed',
        tag: 'storage_service',
      );
    }
  }

  /// Save favorite book IDs for the signed-in account. Throws
  /// [StateError] when signed out: there is no account key to write
  /// to, and silently dropping the write would lose the favorite.
  Future<void> saveFavorites(List<String> bookIds) async {
    final accountId = await currentAccountId();
    if (accountId == null) {
      throw StateError('cannot save favorites: no signed-in account');
    }
    await migrateLegacyFavoritesFor(accountId);
    await (await HiveService.libraryBoxAsync())
        .put(favoritesKeyFor(accountId), bookIds);
  }

  /// Get favorite book IDs for the signed-in account ([] when signed
  /// out — a signed-out user has no account list to show).
  Future<List<String>> getFavorites() async {
    final accountId = await currentAccountId();
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
    final accountId = await currentAccountId();
    if (accountId == null) {
      throw StateError('cannot add favorite: no signed-in account');
    }
    await migrateLegacyFavoritesFor(accountId);
    final key = favoritesKeyFor(accountId);
    final favorites = _readFavoritesForKey(key);
    if (!favorites.contains(bookId)) {
      favorites.add(bookId);
      await (await HiveService.libraryBoxAsync()).put(key, favorites);
    }
  }

  /// Remove a book from the signed-in account's favorites. Throws
  /// [StateError] when signed out (see [saveFavorites]).
  Future<void> removeFavorite(String bookId) async {
    final accountId = await currentAccountId();
    if (accountId == null) {
      throw StateError('cannot remove favorite: no signed-in account');
    }
    await migrateLegacyFavoritesFor(accountId);
    final key = favoritesKeyFor(accountId);
    final favorites = _readFavoritesForKey(key);
    favorites.remove(bookId);
    await (await HiveService.libraryBoxAsync()).put(key, favorites);
  }

  /// Check whether a book is in the signed-in account's favorites
  /// (false when signed out).
  Future<bool> isFavorite(String bookId) async {
    final accountId = await currentAccountId();
    if (accountId == null) return false;
    await migrateLegacyFavoritesFor(accountId);
    final favorites = _readFavoritesForKey(favoritesKeyFor(accountId));
    return favorites.contains(bookId);
  }
}
