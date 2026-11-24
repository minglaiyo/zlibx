// Ported from warreth/OpenlibExtended (AGPL-3.0) — Anna's Archive / LibGen
// book sources. Original file: lib/services/challenge_html_cache.dart
// zlibx is AGPL-3.0 (see LICENSE); upstream MIT attribution for
// shiyi-0x7f/olib-mobile is preserved in LICENSE.
// Cache for HTML pages captured by the challenge solver, keyed by request URL.
//
// When DDoS-Guard blocks every mirror, the solver opens a real browser, lets it
// pass the challenge, and captures the fully rendered page. That HTML is the
// ONLY trustworthy result of that request - replaying cookies through Dio never
// works because the clearance is bound to the browser. This cache hands the
// captured HTML back to the caller (search/bookInfo retry, "Try Again" button)
// so the data survives even after the webview is gone.

// Dart imports:

// Project imports:
import 'package:zlibx/services/external_logger.dart';

class ChallengeHtmlCache {
  ChallengeHtmlCache._();

  static final AppLogger _logger = AppLogger();

  static const _ttl = Duration(minutes: 10);

  /// Upper bounds so a long session can never hold unbounded HTML in
  /// memory: at most [maxEntries] pages and [maxTotalChars] characters in
  /// total (UTF-16 code units, roughly 2 bytes each). A single page above
  /// [maxEntryChars] is not cached at all.
  static const maxEntries = 24;
  static const maxTotalChars = 6 * 1000 * 1000;
  static const maxEntryChars = 3 * 1000 * 1000;

  // Full request URL -> (html, capturedAt). Insertion order = age order.
  static final Map<String, _CacheEntry> _entries = {};
  static int _totalChars = 0;

  static int get entryCount => _entries.length;
  static int get totalChars => _totalChars;

  /// Whether [html] is Chromium's built-in network error page
  /// ("Webpage not available") rather than real content (H1). A dead
  /// mirror / DNS failure loads this page, and onLoadStop still fires —
  /// without this check the error page is captured, cached for 10
  /// minutes, and parsed as an empty result list. The markers are
  /// Chromium-internal strings that never appear on the sites this
  /// solver visits (Z-Library / Anna's Archive / LibGen).
  static bool isBrowserErrorPage(String html) {
    final h = html.toLowerCase();
    return h.contains('chrome-error://') ||
        h.contains('net::err_') ||
        h.contains('webpage not available');
  }

  static void store(String url, String html) {
    if (url.isEmpty ||
        html.isEmpty ||
        html.length > maxEntryChars ||
        isBrowserErrorPage(html)) {
      return;
    }
    _remove(url); // re-inserting moves the key to the "newest" end
    _entries[url] = _CacheEntry(html: html, capturedAt: DateTime.now());
    _totalChars += html.length;
    _evictExpired();
    while (_entries.length > maxEntries || _totalChars > maxTotalChars) {
      _remove(_entries.keys.first);
    }
    _logger.debug(
      'Cached challenge HTML',
      tag: 'ChallengeCache',
      metadata: {'size': html.length, 'entries': _entries.length},
    );
  }

  /// Returns the cached HTML for [url] if it is fresh, otherwise null.
  /// A fresh entry is one captured within the TTL.
  static String? get(String url) {
    if (url.isEmpty) return null;
    _evictExpired();
    return _entries[url]?.html;
  }

  static bool has(String url) => get(url) != null;

  /// Drops everything. Called on login / logout: captured pages can be
  /// account-specific, and the key is only the URL.
  static void clear() {
    _entries.clear();
    _totalChars = 0;
  }

  static void _remove(String url) {
    final removed = _entries.remove(url);
    if (removed != null) _totalChars -= removed.html.length;
  }

  static void _evictExpired() {
    final now = DateTime.now();
    final expired = [
      for (final e in _entries.entries)
        if (now.difference(e.value.capturedAt) > _ttl) e.key,
    ];
    expired.forEach(_remove);
  }
}

class _CacheEntry {
  final String html;
  final DateTime capturedAt;

  _CacheEntry({required this.html, required this.capturedAt});
}
