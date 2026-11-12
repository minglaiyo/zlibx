import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/utils/diagnostics.dart';

import 'booklist_solver.dart';
import 'wall_cookie_bridge.dart';
import 'webview_challenge_solver.dart';

/// Data layer for the cloud download history: the site's `/users/dstats`
/// page (fast Dio first, the WebView solver on the browser-check wall)
/// and its parsing.
///
/// The eapi downloaded list is NOT this data — records made on other
/// devices / through the website are absent from it — so the history is
/// read from the site page itself, the same one the website's 下载历史
/// screen renders. The page is plain server-rendered HTML; on walled
/// mirrors Dio gets the browser-check 503 and the request goes through
/// the same challenge-solver flow the booklists / article / full-text
/// pages use (solve once → wall cookies bridged back into Dio → the
/// remaining pages load fast again).
class DownloadStatsRepository {
  DownloadStatsRepository(this._api);

  final ZLibraryApi _api;

  /// One history page through fast Dio (50 rows, newest first).
  Future<ApiResponse<List<Book>>> fetchPage({int page = 1}) =>
      _api.getUserDownloadHistoryPage(page: page);

  /// The full page URL — the solver fallback's target.
  String pageUrl({int page = 1}) => _api.downloadStatsPageUrl(page: page);

  /// The plugin's short error for a browser-check wall (plus the older
  /// shapes a wall can surface as) — same matcher as the other HTML
  /// domains.
  bool isChallengeError(String? error) =>
      BooklistSolver.isChallengeError(error);

  /// Parses solver-fetched HTML into one page's records, or null when
  /// the document is not a download-history page at all (the solver
  /// landed on a login page or somewhere else entirely) — the caller
  /// then keeps the original challenge error instead of reading the
  /// wrong page as an empty history. A genuine dstats document with no
  /// rows (empty history) parses to an empty list.
  List<Book>? parsePage(String html) {
    const markers = ['dstats-row', 'dstats-content', 'dstats-form'];
    if (!markers.any(html.contains)) return null;
    return parseDownloadStatsPage(html);
  }

  /// Fetches [url] through the WebView solver and returns the real page
  /// HTML, or null when the solve failed. When [userId] and [userKey]
  /// are both given, the login session is installed into the WebView's
  /// CookieManager first — the history page needs the signed-in session
  /// like the own-lists pages do. On success the wall-clearance cookies
  /// are handed back to Dio (the remaining pages then load fast again).
  /// Same contract as [ArticleRepository.fetchViaSolver]: the solved
  /// page is not stored in any cache.
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
    await _bridgeWallCookies(url);
    return html;
  }

  /// Same as [fetchViaSolver] but through the visible solver page only
  /// (no headless attempt). The caller uses it when the first solve
  /// returned HTML that is not the wanted page at all — a bare error
  /// page, or a wall page the headless check mistook for solved. The
  /// visible page lets the wall's JS finish where the user can watch
  /// it, instead of failing outright on a page that was never real.
  Future<String?> fetchViaVisibleSolver(
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
    final html = await WebviewChallengeSolver.fetchHtmlVisibleOnly(url);
    if (html == null ||
        html.isEmpty ||
        BooklistSolver.isChallengeHtml(html)) {
      return null;
    }
    await _bridgeWallCookies(url);
    return html;
  }

  /// Best-effort only: a solved page stays solved even when the cookie
  /// copy fails (the next page just solves again). Never let a
  /// CookieManager failure throw away good HTML — on a test host there
  /// is no WebView platform implementation at all.
  Future<void> _bridgeWallCookies(String url) async {
    try {
      await bridgeWallCookies(_api, url);
    } catch (error) {
      logIgnored('download_stats_repository', error);
    }
  }
}
