import 'package:olib_api_plugin/olib_api_plugin.dart';

import 'booklist_solver.dart';
import 'wall_cookie_bridge.dart';
import 'webview_challenge_solver.dart';

/// Data layer for article search: fetching (fast Dio first, the
/// WebView solver on the browser-check wall) and parsing.
///
/// An article search (`/s/{query}?content_type=article`) is plain
/// HTML; the plugin's [ZLibraryApi.searchArticles] fetches and
/// parses it. Like the full-text pages there is no persistent cache
/// here: searches are read-only listings, so every search revalidates
/// from the network (v1).
class ArticleRepository {
  ArticleRepository(this._api);

  final ZLibraryApi _api;

  /// One page of article search results.
  Future<ApiResponse<ArticleSearchPage>> search({
    required String query,
    String? order,
    int page = 1,
  }) => _api.searchArticles(query: query, order: order, page: page);

  /// The full URL of one article results page — the solver
  /// fallback's URL. Unlike full-text search this route needs no
  /// session token: the query rides in the path and the mode in the
  /// query string, so the bare URL is enough.
  String searchPageUrl({
    required String query,
    String? order,
    int page = 1,
  }) => _api.articlePageUrl(query: query, order: order, page: page);

  /// The plugin's short error for a browser-check wall (plus the older
  /// shapes a wall can surface as) — same matcher as the other HTML
  /// domains.
  bool isChallengeError(String? error) =>
      BooklistSolver.isChallengeError(error);

  /// Parses solver-fetched HTML into a results page, or null when it
  /// fails to parse. Same contract as [FulltextRepository.parsePage]:
  /// a parse failure must not escape the load and leave the screen
  /// loading forever; a page with no `#searchResultBox` is not a
  /// results page at all (the solver most likely landed on the search
  /// form) and is also null, so the caller keeps the original
  /// challenge error instead of painting an empty result. The page
  /// must also echo [expectedQuery] in the search form's `q` input —
  /// the same wrong-page guard the Dio path applies.
  ArticleSearchPage? parsePage(
    String html, {
    required String baseUrl,
    required String expectedQuery,
  }) {
    ArticleSearchPage? page;
    String? error;
    if (!html.contains('searchResultBox')) {
      error = 'no searchResultBox';
    } else {
      final echoed = extractArticleSearchQuery(html);
      if (echoed == null || echoed != expectedQuery.trim()) {
        error = 'query mismatch';
      }
    }
    if (error == null) {
      try {
        page = parseArticleSearchPage(html, baseUrl: baseUrl);
      } catch (_) {
        error = 'parse failed';
      }
    }
    return page;
  }

  /// Fetches [url] through the WebView solver and returns the real
  /// page HTML, or null when the solve failed. When [userId] and
  /// [userKey] are both given, the login session is installed into the
  /// WebView's CookieManager first. Same contract as
  /// [FulltextRepository.fetchViaSolver]: the solved page is NOT
  /// stored in any cache.
  Future<String?> fetchViaSolver(
    String url, {
    String? userId,
    String? userKey,
  }) async {
    final hasSession =
        userId != null && userKey != null && userKey.isNotEmpty;
    if (hasSession) {
      await installSessionCookies(
        userId: userId!,
        userKey: userKey!,
        pageUrl: url,
      );
    }
    try {
      final html = await WebviewChallengeSolver.fetchHtmlAfterChallenge(url);
      if (html == null ||
          html.isEmpty ||
          BooklistSolver.isChallengeHtml(html)) {
        return null;
      }
      await bridgeWallCookies(_api, url);
      return html;
    } finally {
      // O8: the session only lives for this solve (see BooklistSolver).
      if (hasSession) await deleteSessionCookies(pageUrl: url);
    }
  }
}
