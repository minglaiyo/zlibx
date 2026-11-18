// Author aggregation domain of [ZLibraryApi]: the books of one
// author on the `/author/{name}` page. Split out as a mixin in the
// same library, `on ZLibraryCategories`, so it can reuse the
// category page's private fetch helper (`_fetchCategoryPage`) — the
// author page is the same listing shape (z-bookcard results +
// pagerOptions pagination), parsed by [parseCategoryBooksPage].
part of 'zlibrary_api.dart';

/// Author aggregation methods for [ZLibraryApi].
///
/// Shape confirmed from the live page 2026-11-19 (zh.z-library.sk,
/// `/author/[美] 摩根 · 豪泽尔 (Mogan Housel) 著`): the page carries
/// `书籍 (169)` / `文章 (0)` tabs, ~50 `z-bookcard` results per page
/// and `← Prior / 2 / 3 …` pagination — the same listing the
/// category parser consumes, so [getAuthorBooks] returns a
/// [CategoryPage] (books + totalPages; no search slug on this
/// route).
mixin ZLibraryAuthors on ZLibraryCategories {
  /// One page of one author's books. [author] is the exact author
  /// string from the book (the site matches it verbatim); [page] is
  /// 1-based.
  Future<ApiResponse<CategoryPage>> getAuthorBooks({
    required String author,
    int page = 1,
    CancelToken? cancelToken,
  }) {
    return _fetchCategoryPage(
      '/author/${Uri.encodeComponent(author)}',
      queryParameters: {'page': '$page'},
      cancelToken: cancelToken,
    );
  }

  /// The full URL of one author page — the string the app's screens
  /// use for their solver fallback (the WebView follows it with the
  /// session cookies installed).
  String authorPageUrl({required String author, int page = 1}) {
    final query = page > 1 ? '?page=$page' : '';
    return '$_base/author/${Uri.encodeComponent(author)}$query';
  }
}
