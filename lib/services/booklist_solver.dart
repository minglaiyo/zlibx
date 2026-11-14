import 'package:olib_api_plugin/olib_api_plugin.dart';

import 'booklist_html_cache.dart';
import 'wall_cookie_bridge.dart';
import 'webview_challenge_solver.dart';

/// Shared "fast Dio failed, fall back to the WebView challenge solver"
/// helpers for the booklist pages (the list page and the detail page).
///
/// The mirror walls Dio on page routes with a browser-check page; a real
/// WebView engine passes the check and hands back the rendered HTML,
/// which the plugin's parsers turn into the same page models.
class BooklistSolver {
  BooklistSolver._();

  /// The plugin's short error for a browser-check wall
  /// ('HTTP 503: browser check page'), plus the older shapes a wall can
  /// surface as, so the solver fallback triggers on any of them.
  static bool isChallengeError(String? error) {
    if (error == null) return false;
    final lower = error.toLowerCase();
    return lower.contains('browser check') ||
        lower.contains('checking your browser') ||
        lower.contains('ddos-guard') ||
        lower.contains('cf_blocked') ||
        lower.contains('cf-challenge');
  }

  /// A cached page can be a stale challenge page — never parse one as an
  /// (empty) booklist page.
  static bool isChallengeHtml(String html) =>
      WebviewChallengeSolver.isChallengeHtml(html);

  /// Fetch [url] through the WebView solver. Returns the real page HTML,
  /// or null when the solve failed.
  ///
  /// When [userId] and [userKey] are both given, the login session is
  /// installed into the WebView's CookieManager first (own-list pages
  /// need it). On success the wall-clearance cookies are handed to Dio
  /// and the page is stored in [BooklistHtmlCache] under [accountId], so
  /// the next load skips the solver and paints from cache.
  static Future<String?> fetchHtml(
    ZLibraryApi api,
    String url, {
    String? accountId,
    String? userId,
    String? userKey,
  }) async {
    // When this fetch started: a write that invalidates this URL
    // while the solve is in flight must make the store below drop
    // the stale page (see BooklistHtmlCache).
    final fetchedAt = DateTime.now();
    final hasSession =
        userId != null && userKey != null && userKey.isNotEmpty;
    if (hasSession) {
      await installSessionCookies(
        userId: userId,
        userKey: userKey,
        pageUrl: url,
      );
    }
    try {
      // Always fetch live. ChallengeHtmlCache holds pages captured by
      // earlier solves (same-request retries), and a page captured before
      // a write (create/delete) would be served here as a refresh result
      // — the screen then stays stale until a cold start clears the
      // in-memory cache. A solver-path refresh must return current data.
      final html = await WebviewChallengeSolver.fetchHtmlAfterChallenge(url);
      if (html == null || html.isEmpty || isChallengeHtml(html)) return null;
      await bridgeWallCookies(api, url);
      BooklistHtmlCache.store(
        url,
        html,
        accountId: accountId,
        fetchedAt: fetchedAt,
      );
      return html;
    } finally {
      // O8: the session only lives for this solve — drop it so a later
      // anonymous solve cannot silently reuse the old account's
      // cookies. deleteSessionCookies never throws, so a failure here
      // cannot mask the solve result.
      if (hasSession) await deleteSessionCookies(pageUrl: url);
    }
  }
}
