import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import '../utils/app_log.dart';
import '../utils/diagnostics.dart';
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
  static const String _keyServerDownloadHistory = 'server_download_history';

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

  /// 容量淘汰：按 fetchedAt 取最旧的一条（审查 v2 P3）。原先依赖
  /// LinkedHashMap 首键（首次插入序），每轮刷新的条目位置不动，到上
  /// 限时被逐出的恰恰是最热的条目。fetchedAt 缺失的条目视为最旧。
  /// 两个调用点的 map 值类型不同（一个是 `Map<String,dynamic>` 的解码
  /// 产物），这里按 dynamic 读。
  static void _evictOldestEntry(Map<String, dynamic> merged) {
    String? oldestKey;
    var oldestAt = -1;
    merged.forEach((key, value) {
      final at = value is Map ? value['fetchedAt'] : null;
      final n = at is int ? at : 0;
      if (oldestKey == null || n < oldestAt) {
        oldestAt = n;
        oldestKey = key;
      }
    });
    if (oldestKey != null) merged.remove(oldestKey);
  }

  /// The signed-in account's id, or null when signed out or when the
  /// stored credentials cannot be read (secure storage unavailable).
  /// A null here means "no account to scope to": reads see nothing and
  /// writes refuse, rather than touching the shared legacy key.
  Future<String?> _currentAccountId() async {
    try {
      final userId = (await AuthStorage().getCredentials())['userId'];
      return (userId == null || userId.isEmpty) ? null : userId;
    } catch (error) {
      AppLog.report(
        '[storage] cannot resolve account id',
        tag: 'storage_service',
      );
      return null;
    }
  }

  /// Read one favorites list from Hive, tolerating a corrupt entry
  /// (wrong type, non-string ids) as empty instead of crashing the
  /// caller. A corrupt legacy entry must not block the migration.
  /// 迁移键的统一读入口（审查 A1）：library 盒优先；盒还没开（首帧
  /// 前窗口，迁移未跑）回退 settings——旧值还在那儿，同步读不空手。
  Object? _readMoved(String key) {
    final lib = HiveService.libraryBoxOrNull;
    if (lib != null) return lib.get(key);
    return HiveService.settingsBox.get(key);
  }

  List<String> _readFavoritesForKey(String key) {
    final data = _readMoved(key);
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
    final accountId = await _currentAccountId();
    if (accountId == null) return;
    await migrateLegacyFavoritesFor(accountId);
  }

  /// Same migration for an explicit account id. Public (instead of
  /// private) so tests can drive it without a signed-in account.
  Future<void> migrateLegacyFavoritesFor(String accountId) async {
    if (accountId.isEmpty) return;
    try {
      final box = await HiveService.libraryBoxAsync();
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
    final accountId = await _currentAccountId();
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
      await (await HiveService.libraryBoxAsync()).put(key, favorites);
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
    await (await HiveService.libraryBoxAsync()).put(key, favorites);
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

  // ===== Serialized whole-blob JSON writes =====
  //
  // The download history, downloaded-book metadata and book-detail
  // extras are each one JSON blob in the settings box. A Hive `put`
  // is async, so two concurrent read-modify-write calls for the same
  // key would both read the same stale blob — the second write then
  // silently drops the first one's entry. Chaining each write onto
  // the previous write for the same key makes the read-modify-write
  // atomic per key: a chained write only reads after the previous
  // write's `put` completed. Different keys run independently, and
  // pure reads are NOT serialized (they may see a slightly stale
  // snapshot — acceptable for these caches). The map is static on
  // purpose: the Hive box is global, and StorageService is also
  // constructed directly (main.dart, tests) outside the Riverpod
  // singleton, so an instance field would not serialize writes
  // across instances. It holds at most one entry per blob key (a
  // fixed small set), so no cleanup is needed.
  static final Map<String, Future<void>> _writeChains = {};

  /// Run [work] after the previous write for [key] finished, and
  /// return [work]'s own future to the caller. The stored chain
  /// future never completes with an error — a failed write is
  /// swallowed in the chain — so one failure does not block later
  /// writers for the same key; the caller still sees its own
  /// result/error through the returned future.
  static Future<T> _runSerialized<T>(String key, Future<T> Function() work) {
    final previous = _writeChains[key];
    final run = (previous ?? Future<void>.value()).then((_) => work());
    _writeChains[key] = run.then<void>((_) {}).catchError((_, __) {});
    return run;
  }

  // ===== Download History Methods =====

  /// Read the local download-history blob, tolerating a corrupt
  /// entry instead of crashing the caller. Returns {} when the key is
  /// absent (the defaultValue '{}' below), when the stored value is
  /// not a String, when it is not valid JSON, or when the top-level
  /// value is not a Map. A corrupt value is moved to an isolation
  /// backup key (see [_quarantineDownloadHistory]) and the
  /// corruption is logged without the raw value. Entries whose value
  /// is not a Map are dropped, so a malformed entry cannot break a
  /// later field read.
  /// 下载历史逐条键（审查 A2，2026-11-20）：每本书一个 `dl:<bookId>`
  /// 键，值就是条目 Map（hive 原生存储，不再整表 JSON 编解码）；
  /// `dl_order` 保插入序（重加已存在的 id 保持原位——与旧整表 Map 的
  /// 语义一致）。增删 O(1)，一条坏数据只丢自己。
  static const String _dlPrefix = 'dl:';
  static const String _dlOrderKey = 'dl_order';

  /// 插入序 id 列表；顺序表外的条目（手写/迁移残留）按键序补尾，不丢。
  List<String> _readDlOrder(Box<dynamic> box) {
    final ids = <String>[];
    final raw = box.get(_dlOrderKey);
    if (raw is List) {
      for (final item in raw) {
        ids.add('$item');
      }
    }
    for (final key in box.keys) {
      if (key is String && key.startsWith(_dlPrefix)) {
        final id = key.substring(_dlPrefix.length);
        if (!ids.contains(id)) ids.add(id);
      }
    }
    return ids;
  }

  /// Get all download history (insertion order — callers rely on the
  /// map iteration order, same contract as the old whole-table read).
  Future<Map<String, dynamic>> getDownloadHistory() async {
    final box = await HiveService.libraryBoxAsync();
    final history = <String, dynamic>{};
    for (final id in _readDlOrder(box)) {
      final value = box.get('$_dlPrefix$id');
      if (value is Map) {
        history[id] = Map<String, dynamic>.from(value);
      } else if (value != null) {
        AppLog.report(
          '[storage] ignoring corrupt download history entry',
          tag: 'storage_service',
        );
      }
    }
    return history;
  }

  /// Get downloaded file path for a book
  Future<String?> getDownloadedFilePath(String bookId) async {
    final box = await HiveService.libraryBoxAsync();
    final value = box.get('$_dlPrefix$bookId');
    if (value is Map) return value['filePath'] as String?;
    return null;
  }

  /// Add book to download history
  /// Stores: {bookId: {title, author, filePath, cover, extension, downloadTime, source, customSubfolder}}
  /// [source] 是下载来源的枚举名（BookSource.name，#143）：zlibrary /
  /// annasArchive / libgen；旧条目没有这个键，读回来是 null。
  /// [customSubfolder] 是 #95 用户给这本书指定的子文件夹名；没指定
  /// 不存，读回来是 null。
  Future<void> addToDownloadHistory(
    String bookId,
    String title,
    String? author,
    String filePath, {
    String? cover,
    String? extension,
    String? source,
    String? customSubfolder,
  }) async {
    await _runSerialized(_keyDownloadHistory, () async {
      final box = await HiveService.libraryBoxAsync();
      await box.put('$_dlPrefix$bookId', {
        'title': title,
        'author': author,
        'filePath': filePath,
        'cover': cover,
        'extension': extension,
        'downloadTime': DateTime.now().toIso8601String(),
        if (source != null) 'source': source,
        if (customSubfolder != null) 'customSubfolder': customSubfolder,
      });
      final order = _readDlOrder(box);
      if (!order.contains(bookId)) {
        order.add(bookId);
        await box.put(_dlOrderKey, order);
      }
    });
  }

  /// Remove book from download history
  Future<void> removeFromDownloadHistory(String bookId) async {
    await _runSerialized(_keyDownloadHistory, () async {
      final box = await HiveService.libraryBoxAsync();
      await box.delete('$_dlPrefix$bookId');
      final order = _readDlOrder(box);
      if (order.remove(bookId)) {
        await box.put(_dlOrderKey, order);
      }
    });
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
      await (await HiveService.libraryBoxAsync())
          .put(serverDownloadHistoryKeyFor(accountId), booksJson);
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
    final raw = _readMoved(serverDownloadHistoryKeyFor(accountId));
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

  // ===== Downloaded-book metadata cache =====
  //
  // The `/users/downloads` rows carry only id/title/href/time; the
  // author/cover/extension/size come from the eapi downloaded list.
  // Those fields are book-level and essentially immutable, so they are
  // cached per book id and seeded into every history load: covers and
  // authors paint on the FIRST page, and when the cache already covers
  // every row id the eapi pagination is skipped entirely.
  //
  // One global JSON blob (`downloaded_book_metadata`) in the settings
  // box — deliberately NOT account-scoped, unlike the history cache
  // above: which account downloaded a book does not change its author
  // or cover. Same best-effort rules as every cache here: a failed
  // save is logged and ignored, a corrupt read comes back empty.
  // Growth is capped (see [mergeDownloadedBookMetadata]).

  static const String _keyDownloadedBookMetadata = 'downloaded_book_metadata';

  /// 上限：blob 是整读整写，条目无时间戳，超过上限丢先写入的（插入
  /// 序 = Dart Map 的保留序）。一万条 × ~150B 也才 ~1.5MB，正常用户
  /// 触不到；上限只防长期膨胀。
  static const int _downloadedBookMetadataCap = 5000;

  /// The cached overlay metadata per book id, or an empty map. Values
  /// are [Book]s carrying ONLY the five overlay fields (+id) — exactly
  /// what the history overlay reads. A corrupt/non-map blob — or a box
  /// that is not even open (tests) — reads as empty, never throws.
  Map<int, Book> getDownloadedBookMetadataSync() {
    try {
      final raw = _readMoved(_keyDownloadedBookMetadata);
      if (raw is! String || raw.isEmpty) return const <int, Book>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <int, Book>{};
      final out = <int, Book>{};
      for (final entry in decoded.entries) {
        final id = int.tryParse('${entry.key}');
        if (id == null || id <= 0 || entry.value is! Map) continue;
        out[id] = Book.fromJson({
          ...Map<String, dynamic>.from(entry.value as Map),
          'id': id,
        });
      }
      return out;
    } catch (error) {
      AppLog.report(
        '[storage] ignoring corrupt downloaded-metadata cache',
        tag: 'storage_service',
      );
      return const <int, Book>{};
    }
  }

  /// Merge freshly fetched metadata into the cache and persist. The
  /// five overlay fields only (the caller's Books may carry more, but
  /// the history overlay never reads them). Best-effort: a storage
  /// failure is logged, never thrown out of a background load.
  Future<void> mergeDownloadedBookMetadata(Map<int, Book> additions) async {
    if (additions.isEmpty) return;
    await _runSerialized(_keyDownloadedBookMetadata, () async {
      try {
        final merged = <String, Map<String, dynamic>>{
          for (final entry in getDownloadedBookMetadataSync().entries)
            '${entry.key}': _overlayJsonOf(entry.value),
          for (final entry in additions.entries)
            '${entry.key}': _overlayJsonOf(entry.value),
        };
        while (merged.length > _downloadedBookMetadataCap) {
          _evictOldestEntry(merged);
        }
        await (await HiveService.libraryBoxAsync())
            .put(_keyDownloadedBookMetadata, jsonEncode(merged));
      } catch (error) {
        AppLog.report(
          '[storage] downloaded-metadata cache save failed',
          tag: 'storage_service',
        );
      }
    });
  }

  /// The five fields the history overlay reads, as the cached JSON
  /// shape (id is the map key, not repeated inside).
  Map<String, dynamic> _overlayJsonOf(Book book) => {
    'author': book.author,
    'cover': book.cover,
    'extension': book.extension,
    'filesize': book.filesize,
    'filesizeString': book.filesizeString,
  };

  // ===== Book-detail extras cache =====
  //
  // The detail page's volume/ISBN/IPFS/rating rows exist only in the
  // book's HTML page — hundreds of KB, previously fetched fresh on
  // EVERY open (the heaviest single request in the app on a slow
  // mirror). The parsed payload is 7 short strings; volume/ISBN/IPFS
  // are edition constants and only the two community ratings ever
  // change (with the eapi interestScore as the hero's fallback), so
  // they are cached per detail-page path and the provider skips the
  // HTML download entirely within its 7-day freshness window (same
  // TTL convention as BooklistHtmlCache).
  //
  // Key: the page's PATH (`/book/{hash}/{slug}.html`, query stripped
  // by the caller) — stable per edition. One global blob (not
  // account-scoped: bibliographic data does not depend on the
  // account), 2000-entry cap, corrupt reads empty, best-effort
  // writes. Values carry `fetchedAt` (ms since epoch) for the
  // provider's freshness check.

  static const String _keyBookDetailExtras = 'book_detail_extras';
  static const int _bookDetailExtrasCap = 2000;

  /// The cached extras JSON for one detail-page path, or null. The
  /// map carries the seven parsed fields plus `fetchedAt`. A
  /// corrupt/blob-missing/box-not-open situation reads as null,
  /// never throws.
  Map<String, dynamic>? getBookDetailExtrasSync(String pagePath) {
    if (pagePath.isEmpty) return null;
    try {
      final raw = _readMoved(_keyBookDetailExtras);
      if (raw is! String || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final entry = decoded[pagePath];
      if (entry is! Map) return null;
      return Map<String, dynamic>.from(entry);
    } catch (error) {
      AppLog.report(
        '[storage] ignoring corrupt book-detail extras cache',
        tag: 'storage_service',
      );
      return null;
    }
  }

  /// Merge one book's freshly parsed extras into the cache (stamp
  /// `fetchedAt` = now, overwrite the key) and persist. Best-effort:
  /// a storage failure is logged, never thrown out of a page load.
  Future<void> mergeBookDetailExtras(
    String pagePath,
    Map<String, dynamic> fields,
  ) async {
    if (pagePath.isEmpty || fields.isEmpty) return;
    await _runSerialized(_keyBookDetailExtras, () async {
      try {
        final box = await HiveService.libraryBoxAsync();
        final merged = <String, dynamic>{};
        // 已有 blob 的解码单独容错：损坏时丢掉旧内容、用本条重建（修
        // 复性写入），而不是让整次保存失败。
        try {
          final raw = box.get(_keyBookDetailExtras);
          if (raw is String && raw.isNotEmpty) {
            final decoded = jsonDecode(raw);
            if (decoded is Map) {
              decoded.forEach((key, value) {
                if (value is Map) {
                  merged['$key'] = Map<String, dynamic>.from(value);
                }
              });
            }
          }
        } on Object catch (error) {
          // fall through to the repair write below — but leave a trail
          // (审查 v2 P2-2).
          logIgnored('book_detail_extras_read', error);
        }
        merged[pagePath] = {
          ...fields,
          'fetchedAt': DateTime.now().millisecondsSinceEpoch,
        };
        while (merged.length > _bookDetailExtrasCap) {
          _evictOldestEntry(merged);
        }
        await box.put(_keyBookDetailExtras, jsonEncode(merged));
      } catch (error) {
        AppLog.report(
          '[storage] book-detail extras cache save failed',
          tag: 'storage_service',
        );
      }
    });
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
  // ===== settings → library one-time migration (review A1/A2) =====

  /// 迁移完成标志键（留在 settings：它本身就是偏好级的小键）。
  static const String libraryMigratedFlag = 'library_migrated_v1';

  /// 一次性幂等迁移：业务键整体搬进 library，旧整表下载历史转逐条键
  /// （A2）。规则：
  /// - 标志在 → 直接返回；
  /// - library 已有同键不覆盖（首帧前经 [HiveService.libraryBoxAsync]
  ///   提前写入的新值优先于 settings 里的旧值）；
  /// - 旧历史 JSON 解不开 → 原值进 _corrupt 隔离键，不挡其他键；
  /// - 全部搬完才写标志；中途被杀下次启动重跑——搬移动作都是"缺才
  ///   补 + 删源"，重跑等价。
  static Future<void> migrateSettingsToLibrary() async {
    final settings = HiveService.settingsBox;
    if (settings.get(libraryMigratedFlag) == true) return;
    final library = await HiveService.libraryBoxAsync();
    bool isMovedKey(String key) =>
        key == _keyDownloadHistory ||
        key == '${_keyDownloadHistory}_corrupt' ||
        key == _keyDownloadedBookMetadata ||
        key == _keyBookDetailExtras ||
        key.startsWith(_keyFavorites) ||
        key.startsWith(_keyServerDownloadHistory);
    for (final key in List<dynamic>.of(settings.keys)) {
      if (key is! String || !isMovedKey(key)) continue;
      if (!library.containsKey(key)) {
        await library.put(key, settings.get(key));
      }
      await settings.delete(key);
    }
    final legacyRaw = library.get(_keyDownloadHistory);
    if (legacyRaw != null) {
      var converted = false;
      if (legacyRaw is String) {
        try {
          final decoded = jsonDecode(legacyRaw);
          if (decoded is Map) {
            final order = <String>[];
            for (final entry in decoded.entries) {
              if (entry.value is Map) {
                await library.put(
                  '$_dlPrefix${entry.key}',
                  Map<String, dynamic>.from(entry.value as Map),
                );
                order.add('${entry.key}');
              }
            }
            if (!library.containsKey(_dlOrderKey)) {
              await library.put(_dlOrderKey, order);
            }
            converted = true;
          }
        } catch (_) {
          converted = false;
        }
      }
      if (!converted) {
        AppLog.report(
          '[storage] ignoring corrupt download history entry',
          tag: 'storage_service',
        );
        if (!library.containsKey('${_keyDownloadHistory}_corrupt')) {
          await library.put('${_keyDownloadHistory}_corrupt', legacyRaw);
        }
      }
      await library.delete(_keyDownloadHistory);
    }
    await settings.put(libraryMigratedFlag, true);
  }

  // ===== 详情页 eapi 缓存（2026-11-21，实测驱动：短 hash 书每次打开
  // 都白付"注定失败的 fetch1 + 按标题解析"两个往返，重开同一本 0 缓存
  // 全重来——诊断包屏上计时实证 2.3s→5.0s）=====

  /// 详情正文缓存前缀（library 盒）。值 = Book.toJson() + fetchedAt。
  static const String _bookDetailCachePrefix = 'bookdetail:';

  /// 详情正文 7 天 TTL：eapi 的简介/出版社/评分几天内不变，staleness
  /// 换"重开同一本零请求秒开"（惯例同 book_detail_extras 的 7 天）。
  static const Duration _bookDetailCacheTtl = Duration(days: 7);

  /// 取缓存的详情正文（新鲜返回 JSON，过期/缺失/坏形态返回 null）。
  /// best-effort：盒未开（首帧窗口/测试环境无 Hive）直接按未命中——
  /// Hive 未初始化时 openBox 的失败会以未处理异步错误漏出（try/catch
  /// 拦不住，实测），所以门禁必须打在调 openBox 之前。
  Future<Map<String, dynamic>?> getBookDetailCache(String bookId) async {
    if (!HiveService.isLibraryOpen) return null;
    try {
      final box = await HiveService.libraryBoxAsync();
      final raw = box.get('$_bookDetailCachePrefix$bookId');
      if (raw is! Map) return null;
      final fetchedAt = raw['fetchedAt'];
      if (fetchedAt is! int) return null;
      if (DateTime.now().millisecondsSinceEpoch - fetchedAt >=
          _bookDetailCacheTtl.inMilliseconds) {
        return null;
      }
      return Map<String, dynamic>.from(raw);
    } on Object catch (error) {
      logIgnored('book_detail_cache', error);
      return null;
    }
  }

  /// 写详情正文缓存。best-effort：盒未开直接跳过（理由同上）。
  Future<void> putBookDetailCache(
    String bookId,
    Map<String, dynamic> json,
  ) async {
    if (!HiveService.isLibraryOpen) return;
    try {
      final box = await HiveService.libraryBoxAsync();
      await box.put('$_bookDetailCachePrefix$bookId', {
        ...json,
        'fetchedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } on Object catch (error) {
      logIgnored('book_detail_cache', error);
    }
  }

  /// 短 hash → eapi 真 hash 的解析缓存前缀。eapi 的 hash 是书目的规
  /// 范标识，bookId 不变就不变——不设 TTL，写坏也有自愈（取缓存的
  /// hash 若被服务端拒，vendor 照旧走解析重试，app 拿到新解析覆盖回
  /// 去）。
  static const String _eapiHashResolvePrefix = 'eapihash:';

  /// 取解析缓存；无映射返回 null（走原始流程）。best-effort：盒未开
  /// 直接按未命中（理由同 getBookDetailCache）。
  Future<String?> getResolvedEapiHash(String bookId, String hash) async {
    if (!HiveService.isLibraryOpen) return null;
    try {
      final box = await HiveService.libraryBoxAsync();
      final value = box.get('$_eapiHashResolvePrefix$bookId:$hash');
      return value is String && value.isNotEmpty ? value : null;
    } on Object catch (error) {
      logIgnored('book_detail_cache', error);
      return null;
    }
  }

  /// 存解析结果。resolved 与原 hash 相同（'same' 情形）不存。best-effort：
  /// 盒未开直接跳过（理由同 getBookDetailCache）。
  Future<void> putResolvedEapiHash(
    String bookId,
    String hash,
    String resolved,
  ) async {
    if (resolved.isEmpty || resolved == hash) return;
    if (!HiveService.isLibraryOpen) return;
    try {
      final box = await HiveService.libraryBoxAsync();
      await box.put('$_eapiHashResolvePrefix$bookId:$hash', resolved);
    } on Object catch (error) {
      logIgnored('book_detail_cache', error);
    }
  }
}
