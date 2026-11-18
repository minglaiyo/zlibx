import 'package:dio/dio.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import 'booklist_solver.dart';
import 'wall_cookie_bridge.dart';
import 'webview_challenge_solver.dart';

/// Data layer for the author aggregation screen (方案 F2): fetching
/// (`/author/{name}`, fast Dio first, the WebView solver on the
/// browser-check wall) and parsing — the author page is the same
/// z-bookcard listing shape as category pages, parsed by
/// [parseCategoryBooksPage].
///
/// No persistent cache: read-only listings revalidate from the
/// network on every open (same as the category repository).
class AuthorRepository {
  AuthorRepository(this._api);

  final ZLibraryApi _api;

  /// One page of one author's books. [author] is the exact author
  /// string from the book (the site matches it verbatim); [page] is
  /// 1-based.
  Future<ApiResponse<CategoryPage>> fetchBooks({
    required String author,
    int page = 1,
    CancelToken? cancelToken,
  }) => _api.getAuthorBooks(author: author, page: page, cancelToken: cancelToken);

  /// The full URL of one author page — the solver fallback's URL.
  String authorPageUrl({required String author, int page = 1}) =>
      _api.authorPageUrl(author: author, page: page);

  /// The plugin's short error for a browser-check wall.
  bool isChallengeError(String? error) =>
      BooklistSolver.isChallengeError(error);

  /// Parses solver-fetched HTML into a page, or null when it fails to
  /// parse (a broken page is treated like a fetch failure so the
  /// screen never loads forever).
  Future<CategoryPage?> parseBooks(String html, {required String baseUrl}) async {
    try {
      return await parseCategoryBooksPageH(html, baseUrl: baseUrl);
    } catch (_) {
      return null;
    }
  }

  /// Fetches [url] through the WebView solver; same contract as the
  /// category repository's (session installed when given, solved page
  /// not cached).
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
