import 'package:dio/dio.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import 'booklist_solver.dart';
import 'wall_cookie_bridge.dart';
import 'webview_challenge_solver.dart';

/// Data layer for the HTML book search (`/s/{query}`), the fallback
/// channel the eapi search (`POST /eapi/book/search`) defers to.
///
/// Same shape as [ArticleRepository] — Dio first through the plugin,
/// the WebView solver on the browser-check wall — because the route
/// is the same kind of page. No persistent cache: a search is a
/// read-only listing that revalidates from the network every time.
///
/// The channel exists because the eapi search route answers
/// `400 Access denied` on every mirror as of 2026-11-23; see
/// [ZLibraryApi.searchBooksHtml] for the measurement.
class SearchHtmlRepository {
  SearchHtmlRepository(this._api);

  final ZLibraryApi _api;

  /// One page of book search results, fetched and parsed by the
  /// plugin over plain Dio.
  Future<ApiResponse<BookSearchPage>> search({
    required String query,
    String? order,
    int page = 1,
    List<String>? languages,
    List<String>? extensions,
    int? yearFrom,
    int? yearTo,
    bool exact = false,
    CancelToken? cancelToken,
  }) => _api.searchBooksHtml(
    query: query,
    order: order,
    page: page,
    languages: languages,
    extensions: extensions,
    yearFrom: yearFrom,
    yearTo: yearTo,
    exact: exact,
    cancelToken: cancelToken,
  );

  /// The full URL of one results page — the solver fallback's URL.
  /// Like the article route it needs no session token in the URL:
  /// the query rides in the path, the filters in the query string,
  /// and the session is installed into the WebView when signed in.
  String searchPageUrl({
    required String query,
    String? order,
    int page = 1,
    List<String>? languages,
    List<String>? extensions,
    int? yearFrom,
    int? yearTo,
    bool exact = false,
  }) => _api.searchBooksHtmlPageUrl(
    query: query,
    order: order,
    page: page,
    languages: languages,
    extensions: extensions,
    yearFrom: yearFrom,
    yearTo: yearTo,
    exact: exact,
  );

  /// The plugin's short error for a browser-check wall (plus the
  /// older shapes a wall can surface as).
  bool isChallengeError(String? error) =>
      BooklistSolver.isChallengeError(error);

  /// Parses solver-fetched HTML into a results page, or null when it
  /// is not a results page at all. Same contract as
  /// [ArticleRepository.parsePage]: the page must carry
  /// `#searchResultBox` and must echo [expectedQuery] in the form's
  /// `q` input, and a parse throw must not escape the load (a screen
  /// that never gets an answer loads forever). A null answer makes
  /// the caller keep the original error rather than paint an empty
  /// result set.
  Future<BookSearchPage?> parsePage(
    String html, {
    required String baseUrl,
    required String expectedQuery,
  }) async {
    BookSearchPage? page;
    String? error;
    if (!html.contains('searchResultBox')) {
      error = 'no searchResultBox';
    } else {
      final echoed = extractSearchBooksQuery(html);
      if (echoed == null || echoed != expectedQuery.trim()) {
        error = 'query mismatch';
      }
    }
    if (error == null) {
      try {
        page = await parseSearchBooksPageH(html, baseUrl: baseUrl);
      } on Object catch (_) {
        error = 'parse failed';
      }
    }
    return page;
  }

  /// Fetches [url] through the WebView solver and returns the real
  /// page HTML, or null when the solve failed. When [userId] and
  /// [userKey] are both given the login session is installed into the
  /// WebView's CookieManager first, and it only lives for this solve
  /// (see BooklistSolver). The solved page is not stored in any
  /// cache; the wall cookies the solve minted are bridged back into
  /// the plugin so the next plain-Dio request can pass.
  Future<String?> fetchViaSolver(
    String url, {
    String? userId,
    String? userKey,
  }) async {
    final hasSession = userId != null && userKey != null && userKey.isNotEmpty;
    if (hasSession) {
      await installSessionCookies(
        userId: userId,
        userKey: userKey,
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
      if (hasSession) await deleteSessionCookies(pageUrl: url);
    }
  }
}
