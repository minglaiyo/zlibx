import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/utils/diagnostics.dart';

import 'hive_service.dart';


/// Persistent (Hive) cache for booklist HTML pages, keyed by the
/// page's full URL — the same key convention as the in-memory
/// ChallengeHtmlCache.
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
///
/// ── LazyBox storage (审查1 P-2 / 审查3 P3-1) ──
/// The box is a [LazyBox]: a regular Box parses every value into
/// memory at open (~20 MB of page HTML), the LazyBox keeps only the
/// key index and reads values from disk on demand. Two consequences
/// are absorbed here so callers keep working:
///
/// * `LazyBox.get` is async (hive 2.2.3) — [get]/[getBooksPage]/[has]
///   return Futures; the callers were all already inside async chains.
/// * `LazyBox.put` becomes readable only after its disk write awaits —
///   a plain fire-and-forget would silently break "store then read
///   immediately". The [_pending] write-through buffer restores the
///   old synchronous visibility: values live there from [store] until
///   their flush completes (normally microseconds), so same-flow and
///   test reads are deterministic without touching disk.
///
/// Eviction accounting (timestamps + approximate bytes) lives in a
/// small index persisted to the settings box, so the per-store caps
/// are enforced WITHOUT reading every value back — the old in-memory
/// Box implementation decoded all values on every store just to
/// measure them.
class BooklistHtmlCache {
  BooklistHtmlCache._();

  /// Fire-and-forget Hive write/delete with error convergence.
  ///
  /// Cache writes must never block the UI or crash the app on disk errors.
  /// This helper swallows exceptions and records only the tag + exception
  /// type via [logIgnored] (no URLs, keys, or content — see diagnostics.dart).
  static void _safeCacheOp(String tag, Future<void> op) {
    unawaited(op.catchError((Object e, StackTrace st) {
      logIgnored(tag, e);
    }));
  }

  /// Hive box name, shared with [HiveService].
  static const String boxName = HiveService.booklistHtmlBoxName;

  /// Entries older than this read as absent (cold load, as today).
  /// Booklists change slowly; a week bounds staleness while the
  /// background refresh keeps fresh opens up to date.
  static const Duration ttl = Duration(days: 7);

  /// Upper bound on stored pages (each page is tens to low hundreds
  /// of kilobytes); the oldest entries are evicted on store.
  static const int maxEntries = 50;

  /// Upper bound on the total bytes stored in the box. With the index
  /// the cap is advisory for RAM (values no longer live in memory) and
  /// primarily bounds DISK usage; the entry cap remains the RAM proxy.
  static const int maxBytes = 20 * 1024 * 1024;

  static LazyBox<dynamic> get _box => HiveService.booklistHtmlBox;

  /// True when the booklist_html box is open. The box is opened after
  /// the first frame (O2), so until then every access is a cache miss
  /// (reads) or a no-op (writes) — see the guards on the public methods.
  static bool get _ready => Hive.isBoxOpen(boxName);

  // ── write-through buffer ──────────────────────────────────────────────
  // key → value pending a flush, or null = pending delete. Entries are
  // removed the moment the box flush completes; a reader consults this
  // FIRST, so store→read within the same flow sees the write (the
  // guarantee the pre-LazyBox in-memory Box gave for free).
  static final Map<Object, Object?> _pending = {};

  // ── eviction index (persisted as one tiny settings-box entry) ─────────
  // key → (storedAtMs, approxBytes). Advisory: reads never REQUIRE it
  // (values carry their own 'at'); it exists so store-time eviction
  // measures the box without decoding every page.
  static const _indexKey = 'booklist_html_index_v1';
  static Map<String, ({int at, int bytes})>? _index;

  static Map<String, ({int at, int bytes})> get _idx =>
      _index ??= _loadIndex();
  static Map<String, ({int at, int bytes})> _loadIndex() {
    final out = <String, ({int at, int bytes})>{};
    // Settings box unopened (unit tests, exotic boot order): the index
    // degrades to in-memory-only for the process. Production always
    // opens settings before initSecondary.
    if (!Hive.isBoxOpen(HiveService.settingsBoxName)) return out;
    try {
      final raw = HiveService.settingsBox.get(_indexKey);
      if (raw is Map) {
        for (final entry in raw.entries) {
          final value = entry.value;
          if (value is List && value.length >= 2 &&
              value[0] is int && value[1] is int) {
            out[entry.key.toString()] = (
              at: value[0] as int,
              bytes: value[1] as int,
            );
          }
        }
      }
    } on Object catch (error) {
      logIgnored('cache_index_load', error);
    }
    return out;
  }

  static void _persistIndex() {
    if (!Hive.isBoxOpen(HiveService.settingsBoxName)) return;
    final encoded = <String, List<int>>{
      for (final entry in _idx.entries)
        entry.key: [entry.value.at, entry.value.bytes],
    };
    _safeCacheOp('cache_index', HiveService.settingsBox.put(_indexKey, encoded));
  }

  /// One-time-per-process reconciliation of entries that predate the
  /// index (written by older app versions): read each unindexed value
  /// once, register it, and drop any that still carries the legacy
  /// `user_token` JWT. Runs off the critical path (fire-and-forget);
  /// correctness does not depend on it — [get] independently refuses
  /// to ever return a token-bearing page.
  static bool _reconcileDone = false;

  static void _reconcileLegacyOnce() {
    if (_reconcileDone || !_ready) return;
    _reconcileDone = true;
    unawaited(() async {
      try {
        for (final key in _box.keys.toList()) {
          final k = key.toString();
          // The token check is UNCONDITIONAL (index row or not): a
          // direct box write can overwrite an indexed key with a
          // legacy token page, and skipping "known" keys would keep
          // that credential on disk for the rest of the TTL.
          if (_pending.containsKey(key)) continue;
          final raw = await _box.get(key);
          if (raw is! Map) continue;
          final at = raw['at'];
          final html = raw['html'];
          final books = raw['books'];
          if (html is String && html.contains('user_token=')) {
            await _drop(key);
            continue;
          }
          if (!_idx.containsKey(k) &&
              at is int &&
              (html is String || books is List)) {
            _idx[k] = (
              at: at,
              bytes: _entryBytes(
                Map<Object?, Object?>.from(raw),
              ),
            );
          }
        }
        _persistIndex();
      } on Object catch (error) {
        logIgnored('cache_reconcile', error);
      }
    }());
  }

  @visibleForTesting
  static void debugResetTokenSweep() {
    _reconcileDone = false;
  }

  /// Removes session credentials from cached HTML before it is
  /// persisted. The detail page carries the signed-in user's
  /// `user_token` JWT as a card attribute; the parser deliberately
  /// never reads it, and it must never reach Hive either.
  static String _stripSensitive(String html) {
    var clean = html.replaceAll(RegExp(r'''\suser_token="[^"]*"'''), '');
    clean = clean.replaceAll(RegExp(r"""\suser_token='[^']*'"""), '');
    return clean;
  }

  /// Whether a booklist page URL is account-scoped: the own-lists
  /// page (`/booklists/my`), the favorites page (`/booklists/favorite`
  /// — account data, same partition as my; review P1-1) and booklist
  /// detail pages (`/booklist/{id}/...`). Discover (`/booklists`) and
  /// profile pages (`/profile/{id}/{hash}`) are not.
  static bool isPrivateUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    return path == '/booklists/my' ||
        path == '/booklists/favorite' ||
        path.startsWith('/booklist/');
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

  /// The largest stamp handed out so far (see [stamp]).
  static DateTime _lastStamp = DateTime.fromMillisecondsSinceEpoch(0);

  /// 排序用时间戳：把一次 fetch 和同一 URL 的 invalidation 排进同一条
  /// 全序链——每发一个值都严格大于上一个，"后发生"和"后比较"从此是同一
  /// 件事。
  ///
  /// 为什么 [DateTime.now] 不够：Windows 上 VM 的墙钟大约 2 ms 才走一格
  /// （实测连续两次 `DateTime.now()` 1000/1000 次相同），于是"删除之后才
  /// 开始的加载"也可能拿到和 invalidation 一模一样的时间戳；而
  /// [wasInvalidatedAfter] 必须把"不严格更晚"当成过期，这一页就被悄悄丢
  /// 掉了。test/providers/booklist_detail_state_test.dart 之前反复翻脸就
  /// 是这条：假 API 同步返回，删除和下一次加载永远落在同一个 ~2 ms 里。
  ///
  /// 墙钟没动时这里加 1 微秒，保证全序。代价是 stamp 可能比墙钟超前几微
  /// 秒——无所谓，因为 stamp 只和 stamp 比。TTL / 淘汰照旧用
  /// [DateTime.now]（见 [store] 写的 `'at'`）。
  ///
  /// 只把时间戳交给 [store] 的调用方（WebView solver、个人中心页）可以
  /// 继续用 [DateTime.now]：那里最坏结果是一次被丢弃的缓存写入，正是
  /// [_isStaleWrite] 允许的成本。但"要先和 [_invalidatedAt] 比、然后决定
  /// 要不要画到界面上"的时间戳——详情页 controller 的 `fetchedAt`——必须
  /// 从这里取。
  static DateTime stamp() {
    final now = DateTime.now();
    final next = now.isAfter(_lastStamp)
        ? now
        : _lastStamp.add(const Duration(microseconds: 1));
    _lastStamp = next;
    return next;
  }

  /// True when [url] was invalidated after [fetchedAt] — i.e. a fetch
  /// that started at [fetchedAt] predates a write to this URL, so its
  /// data must not be applied or stored. Providers check this before
  /// applying a load's result to the visible list, so a refresh that
  /// started while a remove was still in flight cannot resurrect the
  /// removed book after the remove completed. Same rule as
  /// [_isStaleWrite]: a fetch whose stamp is not strictly later than the
  /// invalidation counts as stale — which is exactly why the stamps that
  /// reach here have to come from [stamp] and not from a raw
  /// [DateTime.now].
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

  /// Value lookup honoring the write-through buffer: pending value →
  /// disk read. Returns the RAW stored object (Map) or null; shape /
  /// TTL validation happens at each typed caller.
  static Future<Object?> _readRaw(dynamic key) async {
    if (_pending.containsKey(key)) return _pending[key];
    return _box.get(key);
  }

  /// Registers a write with the buffer + index and kicks the flush.
  static void _put(String key, Map<String, Object> value, int bytes) {
    final at = value['at'];
    if (at is int) _idx[key] = (at: at, bytes: bytes);
    _pending[key] = value;
    unawaited(() async {
      try {
        await _box.put(key, value);
      } finally {
        // The value is readable from disk from here on; drop the
        // buffer copy. A delete that raced in meanwhile left a null
        // tombstone — only clear it if WE are still the pending entry.
        if (identical(_pending[key], value)) _pending.remove(key);
      }
    }());
    _evictToCaps();
    _persistIndex();
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
    if (!_ready) return; // O2: box opens after the first frame.
    if (_isStaleWrite(url, accountId, fetchedAt)) return;
    _reconcileLegacyOnce();
    final clean = _stripSensitive(html);
    _put(_key(url, accountId), {
      'at': DateTime.now().millisecondsSinceEpoch,
      'html': clean,
    }, clean.length * 2);
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
    // Record the invalidation timestamp even when the box is not yet
    // open (O2): a fetch in flight must still be dropped when it
    // resolves, regardless of whether the box is ready.
    _invalidatedAt[_key(url, accountId)] = stamp();
    if (!_ready) return;
    _dropSync(_key(url, accountId));
    invalidateBooklistPages(url, accountId: accountId);
  }

  /// Drops the parsed JSON pages (`#json-page=N`) of one booklist,
  /// leaving the raw HTML entry alone.
  ///
  /// Records the same invalidation timestamp as
  /// [invalidateBooklist]: the JSON pages and the HTML page carry the
  /// same books, so a stale HTML fetch must not re-store either.
  static void invalidateBooklistPages(String url, {String? accountId}) {
    if (url.isEmpty) return;
    _invalidatedAt[_key(url, accountId)] = stamp();
    if (!_ready) return; // O2: box opens after the first frame.
    final prefix = '$url#json-page=';
    final suffix = accountId == null ? null : '#account=$accountId';
    bool matches(dynamic key) {
      if (key is! String || !key.startsWith(prefix)) return false;
      if (suffix == null) return !key.contains('#account=');
      return key.endsWith(suffix);
    }
    // The write-through buffer MUST be scanned too: a store whose
    // disk flush has not landed yet is invisible to box.keys, and the
    // delete below is enqueued behind that flush (hive serializes per
    // box), so the late write is still removed in the end.
    final keys = <dynamic>{..._box.keys, ..._pending.keys}
        .where(matches)
        .toList();
    for (final key in keys) {
      _dropSync(key);
    }
    if (keys.isNotEmpty) _persistIndex();
  }

  /// Marks a key deleted everywhere at once: pending tombstone (so a
  /// reader never hits the write-through copy), index row, and the
  /// disk delete (fire-and-forget).
  static void _dropSync(dynamic key) {
    _pending[key as Object] = null;
    _idx.remove(key.toString());
    unawaited(() async {
      try {
        await _box.delete(key);
      } finally {
        if (_pending[key] == null) _pending.remove(key);
      }
    }());
  }

  static Future<void> _drop(dynamic key) async {
    // Awaited variant (read-path cleanup): the tombstone keeps every
    // reader away immediately AND the disk delete completes before the
    // caller resumes, so `box.containsKey(key)` is false right after
    // get()/getBooksPage() returned (the fire-and-forget _dropSync
    // cannot promise that on a LazyBox).
    _pending[key as Object] = null;
    _idx.remove(key.toString());
    try {
      await _box.delete(key);
    } on Object catch (error) {
      logIgnored('cache_evict', error);
    } finally {
      _pending.remove(key);
    }
    _persistIndex();
  }

  /// Deletes every entry older than [ttl] (and every index row whose
  /// value vanished). Expired entries otherwise linger until the
  /// 50-entry cap evicts them. Index-driven: no value is read.
  static Future<void> pruneExpired() async {
    if (!_ready) return; // O2: box opens after the first frame.
    final now = DateTime.now().millisecondsSinceEpoch;
    final victims = <Object>[];
    for (final entry in _idx.entries.toList()) {
      if (now - entry.value.at > ttl.inMilliseconds) {
        victims.add(entry.key);
      }
    }
    // Entries the index does not know (direct writes, legacy rows from
    // before the index): read once — same contract as the old
    // full-value scan, just scoped to the unknown remainder.
    for (final key in _box.keys.toList()) {
      final k = key.toString();
      if (_idx.containsKey(k) || _pending.containsKey(key)) continue;
      final raw = await _box.get(key);
      final at = raw is Map ? raw['at'] : null;
      if (raw is! Map || at is! int || now - at > ttl.inMilliseconds) {
        victims.add(key as Object);
      }
    }
    if (victims.isEmpty) return;
    for (final key in victims) {
      _pending[key] = null;
      _idx.remove(key.toString());
    }
    try {
      // Awaited so callers that observe the raw box (tests, the
      // startup bookkeeping path) see the deletes land, matching the
      // synchronous visibility the pre-LazyBox Box gave.
      await _box.deleteAll(victims);
    } on Object catch (error) {
      logIgnored('cache_evict', error);
    } finally {
      for (final key in victims) {
        _pending.remove(key);
      }
    }
    _persistIndex();
  }

  /// The cached HTML for [url], or null when never cached or stale
  /// (older than [ttl]). A stored challenge page is returned as-is —
  /// callers reject it with the solver's challenge check, the same
  /// way they treat the in-memory cache. Expired or corrupt entries
  /// are deleted on read instead of lingering until eviction. A
  /// legacy entry that still carries the `user_token` JWT is dropped
  /// on sight and never returned (see the class doc).
  /// Synchronous fast path over the write-through buffer, for the
  /// "paint from cache the instant a load starts" callers: a page this
  /// process stored moments ago is still flushing (LazyBox only becomes
  /// readable after its disk write), but the buffer holds it. A miss
  /// here is not authoritative — cold-cache callers fall through to the
  /// async [get]/[getBooksPage], which reads the disk too. Nothing is
  /// validated away or deleted on this path beyond shape + TTL; corrupt
  /// or expired rows simply read as absent and the async path cleans
  /// them.
  static String? peekHtml(String url, {String? accountId}) {
    if (url.isEmpty) return null;
    final raw = _pending[_key(url, accountId)];
    if (raw is! Map) return null;
    final at = raw['at'];
    final html = raw['html'];
    if (at is! int || html is! String) return null;
    if (DateTime.now().millisecondsSinceEpoch - at > ttl.inMilliseconds) {
      return null;
    }
    if (html.contains('user_token=')) return null;
    return html;
  }

  /// [peekHtml]'s JSON-page sibling: the buffer copy of one detail
  /// page's books, or null when not (yet) buffered.
  static List<Book>? peekBooksPage(
    String url,
    int page, {
    String? accountId,
  }) {
    if (url.isEmpty) return null;
    final raw = _pending[_key('$url#json-page=$page', accountId)];
    if (raw is! Map) return null;
    final at = raw['at'];
    final books = raw['books'];
    if (at is! int || books is! List) return null;
    if (DateTime.now().millisecondsSinceEpoch - at > ttl.inMilliseconds) {
      return null;
    }
    final good = <Book>[];
    for (final item in books) {
      if (item is! Map) continue;
      try {
        good.add(Book.fromJson(Map<String, dynamic>.from(item)));
      } on Object catch (error) {
        logIgnored('booklist_html_cache', error);
      }
    }
    if (good.isEmpty && books.isNotEmpty) return null;
    return good;
  }

  static Future<String?> get(String url, {String? accountId}) async {
    if (url.isEmpty) return null;
    if (!_ready) return null; // O2: box opens after the first frame.
    _reconcileLegacyOnce();
    final key = _key(url, accountId);
    final raw = await _readRaw(key);
    if (raw is! Map) {
      if (raw != null) await _drop(key);
      return null;
    }
    final at = raw['at'];
    final html = raw['html'];
    if (at is! int || html is! String) {
      await _drop(key);
      return null;
    }
    if (html.contains('user_token=')) {
      await _drop(key);
      return null;
    }
    if (DateTime.now().millisecondsSinceEpoch - at > ttl.inMilliseconds) {
      await _drop(key);
      return null;
    }
    return html;
  }

  static Future<bool> has(String url, {String? accountId}) async =>
      await get(url, accountId: accountId) != null;

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
  static Future<List<Book>?> getBooksPage(
    String url,
    int page, {
    String? accountId,
  }) async {
    if (url.isEmpty) return null;
    if (!_ready) return null; // O2: box opens after the first frame.
    _reconcileLegacyOnce();
    final key = _key('$url#json-page=$page', accountId);
    final raw = await _readRaw(key);
    if (raw is! Map) {
      if (raw != null) await _drop(key);
      return null;
    }
    final at = raw['at'];
    final books = raw['books'];
    if (at is! int || books is! List) {
      await _drop(key);
      return null;
    }
    if (DateTime.now().millisecondsSinceEpoch - at > ttl.inMilliseconds) {
      await _drop(key);
      return null;
    }
    final good = <Book>[];
    for (final item in books) {
      if (item is! Map) continue;
      try {
        good.add(Book.fromJson(Map<String, dynamic>.from(item)));
      } on Object catch (error) {
        logIgnored('booklist_html_cache', error);
      }
    }
    if (good.isEmpty && books.isNotEmpty) {
      // Every entry was bad: the page itself is corrupt.
      await _drop(key);
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
    if (!_ready) return; // O2: box opens after the first frame.
    if (_isStaleWrite(url, accountId, fetchedAt)) return;
    _reconcileLegacyOnce();
    final jsonBooks = books.map((book) => book.toJson()).toList();
    _put(_key('$url#json-page=$page', accountId), {
      'at': DateTime.now().millisecondsSinceEpoch,
      'books': jsonBooks,
    }, _estimateBooksBytes(jsonBooks));
  }

  static Future<void> clear() async {
    if (!_ready) return; // O2: box opens after the first frame.
    await _box.clear();
    _pending.clear();
    _idx.clear();
    _persistIndex();
  }

  /// Approximate stored size of one entry, in bytes. HTML entries
  /// are measured by their string length (UTF-16 code units ≈ 2
  /// bytes each, an over-estimate for ASCII pages — the cap is a
  /// safety bound, not a quota); JSON book pages are measured by the
  /// serialized books list. Corrupt entries count as 0 so they are
  /// evicted first by age, not by size.
  static int _entryBytes(Map<Object?, Object?> raw) {
    final html = raw['html'];
    if (html is String) return html.length * 2;
    final books = raw['books'];
    if (books is List) return _estimateBooksBytes(books);
    return 0;
  }

  static int _estimateBooksBytes(List<Object?> books) {
    var bytes = 0;
    for (final item in books) {
      if (item is Map) bytes += item.length * 64;
    }
    return bytes;
  }

  /// Trims the box back under both caps after every store — using the
  /// index for age/size and `LazyBox.keys` insertion order as the
  /// tie-breaker for legacy entries the index does not know. No value
  /// is read here (the pre-LazyBox implementation decoded every entry
  /// on every single store just to measure them).
  static void _evictToCaps() {
    // Effective live keys: on disk (keystore order ≈ insertion order)
    // minus the delete tombstones still flushing.
    // Live = flushed keys plus the write-through entries still awaiting
    // their put — the store that triggered this eviction is itself one
    // of those, and dropping it from the count lets the cap overshoot.
    bool alive(dynamic key) => !_pending.containsKey(key) || _pending[key] != null;
    final live = <dynamic>{..._box.keys, ..._pending.keys}.where(alive).toList();
    int ageOf(dynamic key) => _idx[key.toString()]?.at ?? 0;
    int bytesOf(dynamic key) => _idx[key.toString()]?.bytes ?? 0;

    // Stable order: indexed age first; un-indexed entries (direct
    // writes, fixtures) keep keystore insertion order and count as
    // oldest — same semantics as the pre-LazyBox implementation,
    // without reading a single value. List.sort is NOT stable, so the
    // tie-break is explicit.
    final enumerated = [
      for (var i = 0; i < live.length; i++) (ageOf(live[i]), i, live[i]),
    ];
    enumerated.sort((a, b) => a.$1 != b.$1
        ? a.$1.compareTo(b.$1)
        : a.$2.compareTo(b.$2));
    final ordered = [for (final e in enumerated) e.$3];
    // Entry cap first: it is the RAM proxy (reads are one value deep).
    var over = ordered.length - maxEntries;
    var total = 0;
    for (final key in ordered) {
      total += bytesOf(key);
    }
    var index = 0;
    while (index < ordered.length && over > 0) {
      total -= bytesOf(ordered[index]);
      _dropSync(ordered[index]);
      index++;
      over--;
    }
    // Then the disk byte cap. Unknown-age legacy entries counted as 0
    // bytes are also bounded by the entry cap above.
    while (index < ordered.length && total > maxBytes) {
      if (ordered.length - index <= 1) break;
      total -= bytesOf(ordered[index]);
      _dropSync(ordered[index]);
      index++;
    }
  }
}
