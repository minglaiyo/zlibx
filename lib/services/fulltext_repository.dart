import 'package:olib_api_plugin/olib_api_plugin.dart';

import 'booklist_solver.dart';
import 'wall_cookie_bridge.dart';
import 'webview_challenge_solver.dart';

/// Data layer for full-text search: fetching (fast Dio first, the
/// WebView solver on the browser-check wall) and parsing.
///
/// A full-text search (`/fulltext/?q=…&token=…&type=…`, 50 hits per
/// page) is plain HTML; the plugin's [ZLibraryApi.searchFullText]
/// fetches and parses it. Like the category pages there is no
/// persistent cache here: searches are read-only listings, so every
/// search revalidates from the network (v1).
class FulltextRepository {
  FulltextRepository(this._api);

  final ZLibraryApi _api;

  /// One page of full-text search results.
  Future<ApiResponse<FullTextSearchPage>> search({
    required String query,
    String type = 'words',
    bool exact = false,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    String? order,
    int page = 1,
  }) => _api.searchFullText(
    query: query,
    type: type,
    exact: exact,
    yearFrom: yearFrom,
    yearTo: yearTo,
    languages: languages,
    extensions: extensions,
    order: order,
    page: page,
  );

  /// The full URL of one full-text results page — the solver
  /// fallback's URL. The cached session token rides along when the
  /// plugin has one; without it the server answers with the search
  /// form instead of results. An explicit [token] overrides the
  /// cached one: the solver fallback passes the token it read from
  /// the token page itself, because the Dio fetch behind the cache
  /// never succeeds on a walled mirror and the cache is empty there.
  String searchPageUrl({
    required String query,
    String type = 'words',
    bool exact = false,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    String? order,
    int page = 1,
    String? token,
  }) => _api.fulltextPageUrl(
    query: query,
    type: type,
    exact: exact,
    yearFrom: yearFrom,
    yearTo: yearTo,
    languages: languages,
    extensions: extensions,
    order: order,
    page: page,
    token: token ?? _api.fulltextToken,
  );

  /// The bare `/fulltext` token page on the same origin as the search
  /// URL — the solver fetches it to read the session token when Dio
  /// is walled and the plugin's cached token is empty. No query
  /// string: the page renders the session token in its search form.
  /// The repository has no direct access to the plugin's private base
  /// URL, so the origin is derived from a search URL (pure string
  /// building, no network).
  String tokenPageUrl() {
    final url = searchPageUrl(query: '');
    return '${Uri.parse(url).origin}/fulltext';
  }

  /// The plugin's short error for a browser-check wall (plus the older
  /// shapes a wall can surface as).
  bool isChallengeError(String? error) =>
      BooklistSolver.isChallengeError(error);

  /// Parses solver-fetched HTML into a results page, or null when it
  /// fails to parse. A parse failure here must not escape the load
  /// (which runs from a microtask) and leave the screen loading
  /// forever — treat a broken page like a fetch failure. A page with
  /// no `#searchResultBox` is not a results page at all (the solver
  /// most likely landed on the search form, e.g. when no token was
  /// available for the URL) — also null, so the caller keeps the
  /// original challenge error instead of painting an empty result.
  /// When [expectedQuery] is given, the page must also echo it in the
  /// search form's `q` input (the same wrong-page guard the Dio path
  /// applies): a solver landing on the default listing for a stale
  /// token echoes a different query or none, and must not be painted.
  FullTextSearchPage? parsePage(
    String html, {
    required String baseUrl,
    String? expectedQuery,
  }) {
    FullTextSearchPage? page;
    String? error;
    if (!html.contains('searchResultBox')) {
      error = 'no searchResultBox';
    } else if (expectedQuery != null) {
      final capped =
          expectedQuery.length > ZLibraryFullText.fulltextMaxQueryLength
              ? expectedQuery.substring(
                  0, ZLibraryFullText.fulltextMaxQueryLength)
              : expectedQuery;
      final echoed = extractFulltextQuery(html);
      if (echoed == null || echoed != capped.trim()) {
        error = fulltextTokenUnavailable;
      }
    }
    if (error == null) {
      try {
        page = parseFullTextSearchPage(html, baseUrl: baseUrl);
      } catch (_) {
        error = 'parse failed';
      }
    }
    return page;
  }

  /// Fetches [url] through the WebView solver and returns the real
  /// page HTML, or null when the solve failed. When [userId] and
  /// [userKey] are both given, the login session is installed into the
  /// WebView's CookieManager first. Unlike [BooklistSolver.fetchHtml]
  /// the solved page is NOT stored in the booklist HTML cache — that
  /// cache is keyed by booklist URLs and search pages do not belong
  /// in it.
  Future<String?> fetchViaSolver(
    String url, {
    String? userId,
    String? userKey,
  }) async {
    // O8: the session cookies live only for this solve — install,
    // solve + bridge, then delete in a `finally` so a failed solve
    // does not leave them in the WebView's CookieManager (same
    // pattern as the category/article repositories).
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
      if (html == null || html.isEmpty || BooklistSolver.isChallengeHtml(html)) {
        return null;
      }
      await bridgeWallCookies(_api, url);
      return html;
    } finally {
      if (hasSession) await deleteSessionCookies(pageUrl: url);
    }
  }
}
