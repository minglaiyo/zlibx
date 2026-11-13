import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/utils/diagnostics.dart';

import 'hive_service.dart';

/// Persistent (Hive) cache for booklist HTML pages, keyed by the
/// page's full URL — the same key convention as the in-memory
/// ChallengeHtmlCache (10-minute TTL, dies on restart).
///
/// Screens paint the last-known page from here instantly, then refresh
/// in the background (stale-while-revalidate); a failed refresh keeps
/// the cached data on screen. Raw HTML is cached, not parsed models,
/// so the existing parsers stay the single source of truth — a cached
/// page is re-parsed on every read, exactly like a fresh load.
///
/// Account-scoped pages (the own-lists page and booklist detail
/// pages) are additionally partitioned by the signed-in account:
/// the same URL serves another account's lists after a switch, so
/// those entries carry an `#account=<id>` suffix on the key. Public
/// pages (discover, profile — the profile URL already carries the
/// viewed user's id + hash) use the plain URL.
///
/// The detail JSON pages (page 2+, `get-books`) are cached here too,
/// as parsed books via `Book.toJson` / `Book.fromJson` — the plugin
/// does not expose the raw JSON body to the app layer, so this is
/// the one place where parsed-model serialization is used. JSON
/// entries share the box-wide TTL and entry cap with the HTML pages.
class BooklistHtmlCache {
  BooklistHtmlCache._();

  /// Hive box name, shared with [HiveService].
  static const String boxName = HiveService.booklistHtmlBoxName;

  /// Entries older than this read as absent (cold load, as today).
  /// Booklists change slowly; a week bounds staleness while the
  /// background refresh keeps fresh opens up to date.
  static const Duration ttl = Duration(days: 7);

  /// Upper bound on stored pages (each page is tens to low hundreds
  /// of kilobytes); the oldest entries are evicted on store.
  static const int maxEntries = 50;

  /// Upper bound on the total bytes stored in the box (P1). A regular
  /// Hive [Box] loads every value into memory when it opens, so the
  /// entry count alone does not bound memory: 50 detail pages at
  /// ~300 KB each is ~15 MB. The byte cap evicts the oldest entries
  /// until the box fits under it (see [_evictOldest]). A full LazyBox
  /// migration would need every sync reader
  /// (`BooklistRepository.cachedDetailHtml` and friends) to become
  /// async — the same ~7-file refactor the user already skipped for
  /// the settings box (item 2) — so the byte cap is the fix, not the
  /// box type.
  static const int maxBytes = 20 * 1024 * 1024;

  static Box<dynamic> get _box {
    final box = HiveService.booklistHtmlBox;
    _sweepTokenHtmlOnce(box);
    return box;
  }

  /// One-time purge of pre-existing cached HTML that still carries the
  /// signed-in user's `user_token` JWT. Older app versions stored the
  /// raw detail HTML verbatim; [store] now strips the token, so any
  /// entry that still has one predates the strip and is dropped once
  /// (the box is a rebuildable cache — it refills from the network).
  /// Runs at most once per process; entries without a token are
  /// untouched, and the 7-day TTL / 50-entry cap are unchanged.
  static bool _tokenSweepDone = false;

  static void _sweepTokenHtmlOnce(Box<dynamic> box) {
    if (_tokenSweepDone) return;
    _tokenSweepDone = true;
    // Delete only the entries that actually contain a legacy token.
    // The cache box also stores safe HTML and parsed JSON pages; wiping
    // every key because one old HTML page is sensitive needlessly drops
    // unrelated, reusable cache entries.
    final sensitiveKeys = <dynamic>[];
    for (final key in box.keys) {
      final value = box.get(key);
      if (value is Map &&
          value['html'] is String &&
          (value['html'] as String).contains('user_token=')) {
        sensitiveKeys.add(key);
      }
    }
    if (sensitiveKeys.isNotEmpty) {
      // Hive applies deletes to its in-memory store synchronously; the
      // Future only represents the disk flush.
      unawaited(box.deleteAll(sensitiveKeys));
    }
  }

  @visibleForTesting
  static void debugResetTokenSweep() {
    _tokenSweepDone = false;
  }

  /// Removes session credentials from cached HTML before it is
  /// persisted. The detail page carries the signed-in user's
  /// `user_token` JWT as a card attribute; the parser deliberately
  /// never reads it, and it must never reach Hive either.
  static String _stripSensitive(String html) {
    var clean = html.replaceAll(
      RegExp(r'''\suser_token="[^"]*"'''),
      '',
    );
    clean = clean.replaceAll(
      RegExp(r"""\suser_token='[^']*'"""),
      '',
    );
    return clean;
  }

  /// Whether a booklist page URL is account-scoped: the own-lists
  /// page (`/booklists/my`) and booklist detail pages
  /// (`/booklist/{id}/...`). Discover (`/booklists`) and profile
  /// pages (`/profile/{id}/{hash}`) are not.
  static bool isPrivateUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    return path == '/booklists/my' || path.startsWith('/booklist/');
  }

  /// Key for one entry: the plain URL for public pages, the URL with
  /// an `#account=<id>` suffix for account-scoped pages. Callers
  /// pass the signed-in user id (or `'signed-out'`) for private
  /// pages and leave [accountId] null for public ones.
  static String _key(String url, String? accountId) =>
      accountId == null ? url : '$url#account=$accountId';

  /// Invalidation timestamps ("tombstones"), one per cache family
  /// (base URL + account partition). [invalidateBooklist] records the
  /// moment a URL was invalidated; a later [store] whose fetch
  /// started at or before that moment is dropped, so a page fetched
  /// before a write (add/remove a book) cannot re-enter the cache
  /// after the write cleared it. In-memory only, process lifetime;
  /// invalidations are rare user actions so the map stays tiny.
  static final Map<String, DateTime> _invalidatedAt = <String, DateTime>{};

  /// True when [url] was invalidated after [fetchedAt] — i.e. a fetch
  /// that started at [fetchedAt] predates a write to this URL, so its
  /// data must not be applied or stored. Providers check this before
  /// applying a load's result to the visible list, so a refresh that
  /// started while a remove was still in flight cannot resurrect the
  /// removed book after the remove completed. Same rule as
  /// [_isStaleWrite]: a fetch from the very same millisecond as the
  /// invalidation counts as stale.
  static bool wasInvalidatedAfter(
    String url,
    DateTime fetchedAt, {
    String? accountId,
  }) {
    final invalidatedAt = _invalidatedAt[_key(url, accountId)];
    if (invalidatedAt == null) return false;
    return !fetchedAt.isAfter(invalidatedAt);
  }

  /// True when a write carrying [fetchedAt] predates the last
  /// invalidation of this URL family and must be dropped. A null
  /// [fetchedAt] (legacy callers, tests) means "no staleness
  /// information" and always writes. A fetch that started in the
  /// very same millisecond as the invalidation is ambiguous;
  /// dropping it only costs a cache miss.
  static bool _isStaleWrite(
    String url,
    String? accountId,
    DateTime? fetchedAt,
  ) {
    if (fetchedAt == null) return false;
    return wasInvalidatedAfter(url, fetchedAt, accountId: accountId);
  }

  static void _put(Object key, Map<String, Object> value) {
    final box = _box;
    // Hive writes to memory synchronously, so the entry is visible to
    // readers (and to the eviction below) immediately; the returned
    // Future only covers the disk flush, which is intentionally
    // fire-and-forget.
    unawaited(box.put(key, value));
    _evictOldest(box);
    // The byte cap applies even when the entry count is under the cap:
    // a few very large pages can exceed it on their own.
    _evictOversize(box);
  }

  /// Stores one HTML page. [fetchedAt] is when the fetch that
  /// produced this page started; a page fetched before the URL's
  /// last invalidation is dropped instead of stored (see
  /// [_invalidatedAt]). Callers that do not know when the fetch
  /// started pass nothing and always write.
  static void store(
    String url,
    String html, {
    String? accountId,
    DateTime? fetchedAt,
  }) {
    if (url.isEmpty || html.isEmpty) return;
    if (_isStaleWrite(url, accountId, fetchedAt)) return;
    _put(_key(url, accountId), {
      'at': DateTime.now().millisecondsSinceEpoch,
      'html': _stripSensitive(html),
    });
  }

  /// Drops every cached entry for one booklist: the raw detail HTML
  /// plus all of its parsed JSON pages (page 1, 2, ...). Use after a
  /// write (add/remove a book, delete the list) so a later open
  /// re-fetches instead of painting stale rows.
  ///
  /// Also records an invalidation timestamp for the URL family, so
  /// a fetch that started before this call cannot re-store its stale
  /// page afterwards (see [_invalidatedAt]).
  static void invalidateBooklist(String url, {String? accountId}) {
    if (url.isEmpty) return;
    final box = _box;
    unawaited(box.delete(_key(url, accountId)));
    invalidateBooklistPages(url, accountId: accountId);
    _invalidatedAt[_key(url, accountId)] = DateTime.now();
  }

  /// Drops the parsed JSON pages (`#json-page=N`) of one booklist,
  /// leaving the raw HTML entry alone.
  ///
  /// Records the same invalidation timestamp as
  /// [invalidateBooklist]: the JSON pages and the HTML page carry the
  /// same books, so a stale HTML fetch must not re-store either.
  static void invalidateBooklistPages(String url, {String? accountId}) {
    if (url.isEmpty) return;
    final box = _box;
    final prefix = '$url#json-page=';
    final suffix = accountId == null ? null : '#account=$accountId';
    final keys = box.keys.whereType<String>().where((key) {
      if (!key.startsWith(prefix)) return false;
      if (suffix == null) return !key.contains('#account=');
      return key.endsWith(suffix);
    }).toList();
    for (final key in keys) {
      unawaited(box.delete(key));
    }
    _invalidatedAt[_key(url, accountId)] = DateTime.now();
  }

  /// Deletes every entry older than [ttl] (and every entry with no
  /// usable timestamp). Expired entries otherwise linger until the
  /// 50-entry cap evicts them.
  static void pruneExpired() {
    final box = _box;
    final now = DateTime.now().millisecondsSinceEpoch;
    final keys = box.keys.where((key) {
      final raw = box.get(key);
      if (raw is! Map) return true;
      final at = raw['at'];
      if (at is! int) return true;
      return now - at > ttl.inMilliseconds;
    }).toList();
    for (final key in keys) {
      unawaited(box.delete(key));
    }
  }

  /// The cached HTML for [url], or null when never cached or stale
  /// (older than [ttl]). A stored challenge page is returned as-is —
  /// callers reject it with the solver's challenge check, the same
  /// way they treat the in-memory cache. Expired or corrupt entries
  /// are deleted on read instead of lingering until eviction.
  static String? get(String url, {String? accountId}) {
    if (url.isEmpty) return null;
    final box = _box;
    final key = _key(url, accountId);
    final raw = box.get(key);
    if (raw is! Map) {
      if (raw != null) unawaited(box.delete(key));
      return null;
    }
    final at = raw['at'];
    final html = raw['html'];
    if (at is! int || html is! String) {
      unawaited(box.delete(key));
      return null;
    }
    if (DateTime.now().millisecondsSinceEpoch - at > ttl.inMilliseconds) {
      unawaited(box.delete(key));
      return null;
    }
    return html;
  }

  static bool has(String url, {String? accountId}) =>
      get(url, accountId: accountId) != null;

  /// Books of one detail page (page 1 is HTML; page 2+ is JSON), or null
  /// when never cached, stale, or corrupt. The key is the detail URL + page,
  /// with the same account partition as [store]. Stale or corrupt
  /// entries are deleted on read instead of lingering until eviction.
  ///
  /// A bad ENTRY and a bad PAGE are different: one entry whose JSON
  /// fails to parse is skipped and the good books are still returned;
  /// only a page whose every entry is bad counts as corrupt and is
  /// deleted. An empty stored list is a valid empty page, not a
  /// corrupt one.
  static List<Book>? getBooksPage(
    String url,
    int page, {
    String? accountId,
  }) {
    if (url.isEmpty) return null;
    final box = _box;
    final key = _key('$url#json-page=$page', accountId);
    final raw = box.get(key);
    if (raw is! Map) {
      if (raw != null) unawaited(box.delete(key));
      return null;
    }
    final at = raw['at'];
    final books = raw['books'];
    if (at is! int || books is! List) {
      unawaited(box.delete(key));
      return null;
    }
    if (DateTime.now().millisecondsSinceEpoch - at > ttl.inMilliseconds) {
      unawaited(box.delete(key));
      return null;
    }
    final good = <Book>[];
    for (final item in books) {
      if (item is! Map) continue;
      try {
        good.add(Book.fromJson(Map<String, dynamic>.from(item)));
      } catch (error) {
        logIgnored('booklist_html_cache', error);
      }
    }
    if (good.isEmpty && books.isNotEmpty) {
      // Every entry was bad: the page itself is corrupt.
      unawaited(box.delete(key));
      return null;
    }
    return good;
  }

  static void storeBooksPage(
    String url,
    int page,
    List<Book> books, {
    String? accountId,
    DateTime? fetchedAt,
  }) {
    if (url.isEmpty) return;
    if (_isStaleWrite(url, accountId, fetchedAt)) return;
    _put(_key('$url#json-page=$page', accountId), {
      'at': DateTime.now().millisecondsSinceEpoch,
      'books': books.map((book) => book.toJson()).toList(),
    });
  }

  static Future<void> clear() => _box.clear();

  /// Approximate stored size of one entry, in bytes. HTML entries
  /// are measured by their string length (UTF-16 code units ≈ 2
  /// bytes each, an over-estimate for ASCII pages — the cap is a
  /// safety bound, not a quota); JSON book pages are measured by the
  /// serialized books list. Corrupt entries count as 0 so they are
  /// evicted first by age, not by size.
  static int _entryBytes(Object? raw) {
    if (raw is! Map) return 0;
    final html = raw['html'];
    if (html is String) return html.length * 2;
    final books = raw['books'];
    if (books is List) {
      var bytes = 0;
      for (final item in books) {
        if (item is Map) bytes += item.length * 64;
      }
      return bytes;
    }
    return 0;
  }

  static void _evictOldest(Box<dynamic> box) {
    if (box.length <= maxEntries) return;
    // Entries carry their own timestamp; drop the oldest until the
    // cap holds. A corrupt entry (no usable timestamp) counts as
    // oldest so it is evicted first.
    final atByKey = <Object?, int>{};
    for (final key in box.keys) {
      final raw = box.get(key);
      var at = 0;
      if (raw is Map && raw['at'] is int) at = raw['at'] as int;
      atByKey[key] = at;
    }
    final keys = atByKey.keys.toList()
      ..sort((a, b) => atByKey[a]!.compareTo(atByKey[b]!));
    for (var i = 0; i < keys.length - maxEntries; i++) {
      unawaited(box.delete(keys[i]));
    }
  }

  /// Evicts the oldest entries until the box fits under [maxBytes]
  /// (P1). Runs after every store (via [_evictOldest]) so the box
  /// never grows past the cap. A single entry larger than the cap is
  /// kept — dropping it would make its URL uncacheable forever — but
  /// it still counts toward the total, so the next store evicts
  /// everything older than it.
  static void _evictOversize(Box<dynamic> box) {
    var total = 0;
    final bytesByKey = <Object?, int>{};
    for (final key in box.keys) {
      final bytes = _entryBytes(box.get(key));
      bytesByKey[key] = bytes;
      total += bytes;
    }
    if (total <= maxBytes) return;
    final atByKey = <Object?, int>{};
    for (final key in box.keys) {
      final raw = box.get(key);
      var at = 0;
      if (raw is Map && raw['at'] is int) at = raw['at'] as int;
      atByKey[key] = at;
    }
    final keys = atByKey.keys.toList()
      ..sort((a, b) => atByKey[a]!.compareTo(atByKey[b]!));
    for (final key in keys) {
      if (total <= maxBytes) break;
      if (box.length <= 1) break;
      total -= bytesByKey[key] ?? 0;
      unawaited(box.delete(key));
    }
  }
}
