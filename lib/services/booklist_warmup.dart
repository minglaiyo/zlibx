import 'package:olib_api_plugin/olib_api_plugin.dart';

import 'booklist_html_cache.dart';
import 'challenge_html_cache.dart';
import 'external_logger.dart';
import 'wall_cookie_bridge.dart';
import 'webview_challenge_solver.dart';

/// Background warm-up for the two fixed booklist list pages
/// (`/booklists/my` and `/booklists`, page 1, no query).
///
/// The list pages are single HTML documents, and a cold open waits on
/// the WebView challenge solver when the mirror walls Dio. Warming
/// them once after sign-in — solving the wall in a headless WebView,
/// bridging the clearance cookies to Dio, and persisting the HTML —
/// means the first real open paints from cache and its refresh goes
/// through fast Dio instead of solving again.
///
/// Headless only: the solve never consults the visible solver
/// fallback, so this can never pop a challenge screen over the home
/// page. Fire-and-forget and single-flight per app launch; only
/// runs while signed in. All errors are swallowed (logged only) —
/// a failed warm-up just means the first open solves on demand, as
/// today.
class BooklistWarmup {
  BooklistWarmup._();

  static final AppLogger _logger = AppLogger();

  /// Single-flight per app launch: the warm-up runs at most once,
  /// however often the home screen mounts.
  static bool _started = false;

  static Future<void> warmUp({
    required ZLibraryApi api,
    required User? user,
  }) async {
    final userKey = user?.remixUserkey;
    if (user == null || userKey == null || userKey.isEmpty) return;
    if (!WebviewChallengeSolver.isSupported) return;
    if (_started) return;
    _started = true;
    try {
      // Deliberately serial, not Future.wait: the two pages share one
      // host and one global CookieManager (see wall_cookie_bridge),
      // and fetchHtmlHeadlessOnly has no in-flight dedup, so parallel
      // calls would run two headless WebViews at once. Serial also
      // lets the second solve reuse the first solve's wall-clearance
      // cookies from the shared CookieManager, so it is often
      // near-free. The cache checks inside _warmOne already skip a
      // page that is warm, so the serial cost is at most one solve.
      //
      // The URLs must match the booklists screen's page-1 loads
      // exactly (same builder, same arguments) so the warmed HTML
      // and cookies land under the cache keys the screen reads.
      final mineOk = await _warmOne(
        api,
        user,
        api.booklistsPageUrl(mine: true, order: 'popular', page: 1),
        needsSession: true,
        // The mine page is account-scoped: store it under this
        // account's partition, the same key the screen reads.
        accountId: user.id,
      );
      final discoverOk = await _warmOne(
        api,
        user,
        api.booklistsPageUrl(mine: false, order: 'popular', page: 1),
        needsSession: false,
      );
      if (!mineOk || !discoverOk) {
        // A failed page can be retried by a later warmUp call; the
        // pages that did warm short-circuit via the cache on retry.
        // Concurrent calls still saw _started == true while this
        // run was in flight, so single-flight is preserved.
        _started = false;
      }
    } catch (e) {
      _logger.debug(
        'Booklist warm-up failed',
        tag: 'BooklistWarmup',
        metadata: {'error': e.toString()},
      );
      _started = false;
    }
  }

  /// Warm one page: skip when the in-memory cache already holds a
  /// real page for it, otherwise solve headless, persist the HTML,
  /// and bridge the clearance cookies to Dio. Returns true when the
  /// page is warm afterwards (already cached or freshly solved),
  /// false when it could not be warmed.
  static Future<bool> _warmOne(
    ZLibraryApi api,
    User user,
    String url, {
    required bool needsSession,
    String? accountId,
  }) async {
    try {
      final warm = ChallengeHtmlCache.get(url);
      if (warm != null && !WebviewChallengeSolver.isChallengeHtml(warm)) {
        return true;
      }
      // The in-memory cache only lasts ~10 minutes, but the solved page
      // is ALSO persisted for 7 days (BooklistHtmlCache). Without this
      // second check every cold start re-ran a headless solve (up to a
      // minute of WebView work) for a page the app already had on disk.
      if (BooklistHtmlCache.get(url, accountId: accountId) != null) {
        return true;
      }
      bool installed = false;
      if (needsSession) {
        installed = true;
        await installSessionCookies(
          userId: user.id,
          userKey: user.remixUserkey,
          pageUrl: url,
        );
      }
      try {
        // When this fetch started, for the invalidation check on the
        // store below (see BooklistHtmlCache).
        final fetchedAt = DateTime.now();
        final html = await WebviewChallengeSolver.fetchHtmlHeadlessOnly(url);
        if (html == null ||
            html.isEmpty ||
            WebviewChallengeSolver.isChallengeHtml(html)) {
          return false;
        }
        BooklistHtmlCache.store(
          url,
          html,
          accountId: accountId,
          fetchedAt: fetchedAt,
        );
        await bridgeWallCookies(api, url);
        return true;
      } finally {
        // O8: drop the session cookies once the warm-up is done so they
        // do not linger in the WebView's CookieManager.
        if (installed) await deleteSessionCookies(pageUrl: url);
      }
    } catch (e) {
      _logger.debug(
        'Booklist warm-up failed for page',
        tag: 'BooklistWarmup',
        metadata: {'url': url, 'error': e.toString()},
      );
      return false;
    }
  }
}
