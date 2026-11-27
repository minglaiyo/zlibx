import 'dart:convert';

import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../utils/app_log.dart';
import '../hive_service.dart';
import 'storage_keys.dart';
import 'storage_shared.dart';
import 'storage_write_queue.dart';

/// Server-side download history cache + downloaded-book metadata
/// overlay, split out of `storage_service.dart` (P1-4). Moved
/// verbatim; no behavior change, no key-name change.
class ServerHistoryRepository {
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
    final accountId = await currentAccountId();
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
    final raw = readMovedValue(serverDownloadHistoryKeyFor(accountId));
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
      books.sort(downloadedAtDesc);
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
    final accountId = await currentAccountId();
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

  /// The cached overlay metadata per book id, or an empty map. Values
  /// are [Book]s carrying ONLY the five overlay fields (+id) — exactly
  /// what the history overlay reads. A corrupt/non-map blob — or a box
  /// that is not even open (tests) — reads as empty, never throws.
  Map<int, Book> getDownloadedBookMetadataSync() {
    try {
      final raw = readMovedValue(kDownloadedBookMetadataKey);
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
    await StorageWriteQueue.runSerialized(kDownloadedBookMetadataKey, () async {
      try {
        final merged = <String, Map<String, dynamic>>{
          for (final entry in getDownloadedBookMetadataSync().entries)
            '${entry.key}': _overlayJsonOf(entry.value),
          for (final entry in additions.entries)
            '${entry.key}': _overlayJsonOf(entry.value),
        };
        while (merged.length > kDownloadedBookMetadataCap) {
          evictOldestEntry(merged);
        }
        await (await HiveService.libraryBoxAsync())
            .put(kDownloadedBookMetadataKey, jsonEncode(merged));
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
}
