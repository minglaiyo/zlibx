import 'package:dio/dio.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import 'booklist_solver.dart';
import 'wall_cookie_bridge.dart';
import 'webview_challenge_solver.dart';

/// Data layer for the category browsing screens: fetching (fast Dio
/// first, the WebView solver on the browser-check wall) and parsing.
///
/// A category page (`/category/{id}`, `?page=N`) is plain HTML; the
/// plugin's [ZLibraryApi.getCategoryBooks] fetches and parses it
/// with [parseCategoryBooksPage] — the category page's own parser,
/// which keeps the per-card `deleted`/`favorite` flags and the
/// page's `pagerOptions` total. Unlike the booklist repository there
/// is no persistent cache here: category pages are read-only
/// listings, so every open revalidates from the network (v1).
class CategoryRepository {
  CategoryRepository(this._api);

  final ZLibraryApi _api;

  /// One page of books in [categoryId], plus the page count when the
  /// page carries it. [order] is one of the category sort values.
  Future<ApiResponse<CategoryPage>> fetchBooks({
    required int categoryId,
    int page = 1,
    String? order,
    CancelToken? cancelToken,
  }) => _api.getCategoryBooks(categoryId, page: page, order: order, cancelToken: cancelToken);

  /// One page of an in-category search (see
  /// [ZLibraryApi.searchInCategory]).
  Future<ApiResponse<CategoryPage>> searchInCategory({
    required int categoryId,
    String? slug,
    required String query,
    bool exact = false,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    List<String>? contentTypes,
    String? order,
    int page = 1,
    CancelToken? cancelToken,
  }) => _api.searchInCategory(
    categoryId: categoryId,
    slug: slug,
    query: query,
    exact: exact,
    yearFrom: yearFrom,
    yearTo: yearTo,
    languages: languages,
    extensions: extensions,
    contentTypes: contentTypes,
    order: order,
    page: page,
    cancelToken: cancelToken,
  );

  /// The full URL of one category page — the solver fallback's URL
  /// (the WebView follows the bare-id redirect itself).
  String categoryPageUrl({
    required int categoryId,
    int page = 1,
    String? order,
  }) => _api.categoryPageUrl(categoryId, page: page, order: order);

  /// The full URL of an in-category search page — the solver
  /// fallback's URL in search mode.
  String categorySearchUrl({
    required int categoryId,
    String? slug,
    required String query,
    bool exact = false,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
    List<String>? contentTypes,
    String? order,
    int page = 1,
  }) => _api.categorySearchUrl(
    categoryId: categoryId,
    slug: slug,
    query: query,
    exact: exact,
    yearFrom: yearFrom,
    yearTo: yearTo,
    languages: languages,
    extensions: extensions,
    contentTypes: contentTypes,
    order: order,
    page: page,
  );

  /// The plugin's short error for a browser-check wall (plus the older
  /// shapes a wall can surface as).
  bool isChallengeError(String? error) =>
      BooklistSolver.isChallengeError(error);

  /// Parses solver-fetched HTML into a category page, or null when
  /// it fails to parse. A parse failure here must not escape the load
  /// (which runs from a microtask) and leave the screen loading
  /// forever — treat a broken page like a fetch failure.
  /// Async since phase 3: the parse routes through the Rust bridge
  /// when injected (the Dart implementation stays as the fallback).
  Future<CategoryPage?> parseBooks(
    String html, {
    required String baseUrl,
  }) async {
    try {
      return await parseCategoryBooksPageH(html, baseUrl: baseUrl);
    } catch (_) {
      return null;
    }
  }

  /// Fetches [url] through the WebView solver and returns the real
  /// page HTML, or null when the solve failed. When [userId] and
  /// [userKey] are both given, the login session is installed into the
  /// WebView's CookieManager first. Unlike
  /// [BooklistSolver.fetchHtml] the solved page is NOT stored in the
  /// booklist HTML cache — that cache is keyed by booklist URLs and
  /// category pages do not belong in it.
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
      // O8: the session only lives for this solve (see BooklistSolver).
      if (hasSession) await deleteSessionCookies(pageUrl: url);
    }
  }

  /// F1 分类目录树：Dio 直取（双通道的第一条腿）。
  Future<ApiResponse<CategoriesDirectoryPage>> fetchDirectory() =>
      _api.getCategoriesDirectory();

  /// 目录页的绝对地址——solver 回退用（WebView 需要完整 URL）。
  String get categoriesDirectoryUrl => _api.categoriesDirectoryUrl;

  /// Parses solver-fetched directory HTML, or null when it fails to
  /// parse (same contract as [parseBooks]).
  Future<CategoriesDirectoryPage?> parseDirectory(String html) async {
    try {
      return await parseCategoriesDirectoryH(html);
    } catch (_) {
      return null;
    }
  }
}
