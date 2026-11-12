import 'package:olib_api_plugin/olib_api_plugin.dart';

import 'booklist_solver.dart';
import 'wall_cookie_bridge.dart';
import 'webview_challenge_solver.dart';

/// Data layer for one book detail page: the payload
/// ([BookDetailExtras] — metadata rows) the
/// detail screen merges onto the eapi book.
///
/// The page is an HTML route behind the DiamWall, so fetching runs in
/// two stages, like every other HTML route (booklists / full-text /
/// categories):
///
/// 1. The plugin's [ZLibraryApi.fetchBookDetailExtras] over Dio — it
///    follows the wall's cookie hop (`307 + __diamwall`) itself.
/// 2. When that answers a browser-check challenge (`513`/`503` JS
///    wall — a bare Dio client can never pass it, live-verified
///    2026-11-12), the page URL is re-fetched through the WebView
///    solver, which runs the site's own challenge JS and returns the
///    real document. The solved page is parsed with the same plugin
///    parsers, so both stages yield identical data.
///
/// A solver run is only ever triggered on a challenge-shaped failure
/// (`isChallengeError`), never on a plain 404 / network error — a
/// dead book must not pop a WebView.
class BookDetailPageRepository {
  BookDetailPageRepository(this._api);

  final ZLibraryApi _api;

  /// One detail-page payload. `userId` / `userKey` are the signed-in
  /// session for the solver stage (the page is public; the session
  /// only personalises it), passed through from the caller's
  /// [UserProfileArgs]-style session pair.
  Future<ApiResponse<BookDetailExtras>> fetch({
    required String href,
    String? userId,
    String? userKey,
  }) async {
    final first = await _api.fetchBookDetailExtras(href);
    if (first.success) return first;
    if (!isChallengeError(first.error)) return first;
    // The wall escalated to the JS challenge: re-fetch the page
    // through the WebView solver (which executes that JS) and parse
    // the solved document.
    final url = pageUrl(href);
    final html = await fetchViaSolver(url, userId: userId, userKey: userKey);
    if (html == null) return first;
    final parsed = parsePage(html, baseUrl: Uri.parse(url).origin);
    if (parsed == null) return first;
    return ApiResponse.ok(parsed);
  }

  /// The absolute detail-page URL for one site-relative [href] — the
  /// solver fallback's URL (the WebView follows it with the session
  /// cookies installed).
  String pageUrl(String href) => 'https://${_api.domain}$href';

  /// The plugin's short error for a browser-check wall (plus the
  /// older shapes a wall can surface as) — same matcher as the other
  /// HTML routes.
  bool isChallengeError(String? error) =>
      BooklistSolver.isChallengeError(error);

  /// Parses solver-fetched HTML into a detail payload, or null when
  /// it fails to parse — a parse failure must not escape the load and
  /// leave the detail screen stuck; treat a broken page like a fetch
  /// failure. A page with no `bookDetailsBox` is not a book page at
  /// all (the solver most likely landed on the wall or an error
  /// page) — also null.
  BookDetailExtras? parsePage(String html, {required String baseUrl}) {
    if (!html.contains('bookDetailsBox')) return null;
    try {
      return BookDetailExtras(
        metadata: parseBookDetailProperties(html),
      );
    } catch (_) {
      return null;
    }
  }

  /// Fetches [url] through the WebView solver and returns the real
  /// page HTML, or null when the solve failed. When [userId] and
  /// [userKey] are both given, the login session is installed into
  /// the WebView's CookieManager first. Same contract as
  /// [FulltextRepository.fetchViaSolver]: the solved page is NOT
  /// stored in any cache.
  Future<String?> fetchViaSolver(
    String url, {
    String? userId,
    String? userKey,
  }) async {
    if (userId != null && userKey != null && userKey.isNotEmpty) {
      await installSessionCookies(
        userId: userId,
        userKey: userKey,
        pageUrl: url,
      );
    }
    final html = await WebviewChallengeSolver.fetchHtmlAfterChallenge(url);
    if (html == null ||
        html.isEmpty ||
        BooklistSolver.isChallengeHtml(html)) {
      return null;
    }
    await bridgeWallCookies(_api, url);
    return html;
  }
}
