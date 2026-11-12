import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../constants/search_filters.dart';
import '../services/category_repository.dart';
import 'auth_provider.dart';
import 'zlibrary_provider.dart';

/// Arguments for CategoryBooksScreen. Equality is by category id so
/// the screen's provider family resolves to the same controller on
/// rebuild. The name is display-only (the screen title) and is
/// deliberately excluded from equality.
class CategoryBooksArgs {
  final int categoryId;
  final String categoryName;

  const CategoryBooksArgs({
    required this.categoryId,
    required this.categoryName,
  });

  @override
  bool operator ==(Object other) =>
      other is CategoryBooksArgs && other.categoryId == categoryId;

  @override
  int get hashCode => categoryId.hashCode;
}

class CategoryBooksState {
  /// True only while there is no page to paint yet.
  final bool isLoading;
  final bool isLoadingMore;
  final String? error;
  final List<CategoryBook> books;
  final bool hasMore;
  final int nextPage;

  /// Sort order, one of [categorySearchOrders]; `'popular'` default.
  final String order;

  /// In-category search query; empty means browse mode.
  final String query;

  /// Exact-match toggle for the in-category search (`e=1`).
  final bool exact;

  /// Language filter key into [searchLanguageOptions]; `'all'` means
  /// no language filter.
  final String language;

  /// Extension filter key into [searchExtensions]; `'all'` means no
  /// extension filter.
  final String extension;

  /// Year range bounds for the in-category search; null means that
  /// bound is unset.
  final int? yearFrom;
  final int? yearTo;

  /// Content-type filter for the in-category search: a one-element
  /// list (single select) or null for no filter. The values are the
  /// site's `selected_content_types` form values.
  final List<String>? contentTypes;

  /// Total pages from the page's `pagerOptions`, when the page
  /// carries it (null = unknown — never invented).
  final int? totalPages;

  /// First page's card count, the effective page size when
  /// [totalPages] is unknown (a small category's page carries no
  /// `pagerOptions`). Null until page 1 lands.
  final int? effectivePageSize;

  const CategoryBooksState({
    this.isLoading = true,
    this.isLoadingMore = false,
    this.error,
    this.books = const [],
    this.hasMore = true,
    this.nextPage = 2,
    this.order = 'popular',
    this.query = '',
    this.exact = false,
    this.language = 'all',
    this.extension = 'all',
    this.yearFrom,
    this.yearTo,
    this.contentTypes,
    this.totalPages,
    this.effectivePageSize,
  });

  CategoryBooksState copyWith({
    bool? isLoading,
    bool? isLoadingMore,
    String? error,
    bool clearError = false,
    bool clearYearFrom = false,
    bool clearYearTo = false,
    bool clearContentTypes = false,
    List<CategoryBook>? books,
    bool? hasMore,
    int? nextPage,
    String? order,
    String? query,
    bool? exact,
    String? language,
    String? extension,
    int? yearFrom,
    int? yearTo,
    List<String>? contentTypes,
    int? totalPages,
    int? effectivePageSize,
  }) {
    return CategoryBooksState(
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: clearError ? null : (error ?? this.error),
      books: books ?? this.books,
      hasMore: hasMore ?? this.hasMore,
      nextPage: nextPage ?? this.nextPage,
      order: order ?? this.order,
      query: query ?? this.query,
      exact: exact ?? this.exact,
      language: language ?? this.language,
      extension: extension ?? this.extension,
      yearFrom: clearYearFrom ? null : (yearFrom ?? this.yearFrom),
      yearTo: clearYearTo ? null : (yearTo ?? this.yearTo),
      contentTypes:
          clearContentTypes ? null : (contentTypes ?? this.contentTypes),
      totalPages: totalPages ?? this.totalPages,
      effectivePageSize: effectivePageSize ?? this.effectivePageSize,
    );
  }
}

/// Books in one category. Every page is the category page's own HTML
/// (`?page=N`); there is no JSON endpoint and no persistent cache in
/// v1, so every open revalidates from the network.
///
/// Pagination (P0 fix): a category page carries 50 cards, not 10 —
/// the old `books.length == 10` rule set `hasMore` false on a full
/// first page and pages 2–10 were unreachable. `hasMore` now comes
/// from the page's `pagerOptions.pagesTotal` when present
/// (`page < totalPages`); when the page carries no total, the FIRST
/// page's card count is the effective page size and a page is full
/// iff it carries that many cards. A short page is never trusted as
/// "last page" when a total is known.
class CategoryBooksController
    extends
        AutoDisposeFamilyNotifier<CategoryBooksState, CategoryBooksArgs> {
  final List<CategoryBook> _books = [];
  // O(1) membership checks while pages are appended.
  final Set<int> _bookIds = <int>{};

  bool _alive = true;
  int _generation = 0;

  /// Data layer: fetching and parsing (see [CategoryRepository]).
  /// Holds no state of its own; rebuilt on every (re)build from the
  /// shared API instance.
  late CategoryRepository _repository;

  int get _categoryId => arg.categoryId;

  @override
  CategoryBooksState build(CategoryBooksArgs arg) {
    _repository = CategoryRepository(ref.read(zlibraryApiProvider));
    _alive = true;
    ref.onDispose(() => _alive = false);
    Future<void>.microtask(loadFirst);
    return const CategoryBooksState();
  }

  bool _isCurrent(int generation) => _alive && generation == _generation;

  /// Change the list sort order and reload page 1. [order] is one of
  /// [categorySearchOrders].
  void setOrder(String order) {
    if (order == state.order) return;
    state = state.copyWith(order: order);
    unawaited(loadFirst());
  }

  /// Search inside the category (empty query = back to browse mode)
  /// and reload page 1.
  void search(String query) {
    final trimmed = query.trim();
    if (trimmed == state.query) return;
    state = state.copyWith(query: trimmed);
    unawaited(loadFirst());
  }

  /// Change the language filter and reload page 1. [language] is a
  /// key into [searchLanguageOptions] (`'all'` = no filter).
  void setLanguage(String language) {
    if (language == state.language) return;
    state = state.copyWith(language: language);
    unawaited(loadFirst());
  }

  /// Change the extension filter and reload page 1. [extension] is
  /// a key into [searchExtensions] (`'all'` = no filter).
  void setExtension(String extension) {
    if (extension == state.extension) return;
    state = state.copyWith(extension: extension);
    unawaited(loadFirst());
  }

  /// Change the exact-match toggle and reload page 1 (only applies
  /// in search mode).
  void setExact(bool exact) {
    if (exact == state.exact) return;
    state = state.copyWith(exact: exact);
    unawaited(loadFirst());
  }

  /// Change the year-from bound and reload page 1 (only applies in
  /// search mode). Null clears the bound.
  void setYearFrom(int? yearFrom) {
    if (yearFrom == state.yearFrom) return;
    state = state.copyWith(
      yearFrom: yearFrom,
      clearYearFrom: yearFrom == null,
    );
    unawaited(loadFirst());
  }

  /// Change the year-to bound and reload page 1 (only applies in
  /// search mode). Null clears the bound.
  void setYearTo(int? yearTo) {
    if (yearTo == state.yearTo) return;
    state = state.copyWith(
      yearTo: yearTo,
      clearYearTo: yearTo == null,
    );
    unawaited(loadFirst());
  }

  /// Change the content-type filter and reload page 1 (only applies
  /// in search mode). A one-element list (single select); null or an
  /// empty list clears the filter.
  void setContentTypes(List<String>? contentTypes) {
    final List<String>? normalized =
        contentTypes == null || contentTypes.isEmpty
            ? null
            : List.of(contentTypes);
    if (_sameStringLists(normalized, state.contentTypes)) return;
    state = state.copyWith(
      contentTypes: normalized,
      clearContentTypes: normalized == null,
    );
    unawaited(loadFirst());
  }

  /// Element-wise equality for nullable string lists.
  bool _sameStringLists(List<String>? a, List<String>? b) {
    if (a == null || b == null) return a == null && b == null;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Clear the language/extension/exact/year/content-type filters
  /// (the sort order and the search query are kept) and reload
  /// page 1.
  void resetFilters() {
    if (state.language == 'all' &&
        state.extension == 'all' &&
        !state.exact &&
        state.yearFrom == null &&
        state.yearTo == null &&
        state.contentTypes == null) {
      return;
    }
    state = state.copyWith(
      language: 'all',
      extension: 'all',
      exact: false,
      clearYearFrom: true,
      clearYearTo: true,
      clearContentTypes: true,
    );
    unawaited(loadFirst());
  }

  Future<void> loadFirst() async {
    if (!_alive) return;
    final generation = ++_generation;
    _books.clear();
    _bookIds.clear();
    // Fresh state, but keep the user's sort / search / filter
    // choices — they are selections, not per-load results.
    state = CategoryBooksState(
      order: state.order,
      query: state.query,
      exact: state.exact,
      language: state.language,
      extension: state.extension,
      yearFrom: state.yearFrom,
      yearTo: state.yearTo,
      contentTypes: state.contentTypes,
    );
    final result = await _loadPage(1, generation: generation);
    if (!_isCurrent(generation)) return;
    final page = result.page;
    if (page == null) {
      state = state.copyWith(
        error: result.error ?? 'Failed to load category',
        isLoading: false,
      );
      return;
    }
    _merge(page.books);
    state = state.copyWith(
      books: List.of(_books),
      hasMore: _hasMoreAfterPage(
        page: 1,
        loadedCount: page.books.length,
        totalPages: page.totalPages,
        effectivePageSize: page.books.length,
      ),
      nextPage: 2,
      totalPages: page.totalPages,
      effectivePageSize: page.books.length,
      isLoading: false,
    );
  }

  /// Load-more for page 2 and up. A failed later page must not
  /// silently end the list: a network blip would look like "no more
  /// books" with no way back. Keep hasMore so the next scroll event
  /// re-enters loadMore and retries.
  Future<void> loadMore() async {
    final s = state;
    if (!_alive ||
        s.isLoading ||
        s.isLoadingMore ||
        !s.hasMore ||
        s.error != null) {
      return;
    }
    final page = s.nextPage;
    final generation = _generation;
    state = state.copyWith(isLoadingMore: true);
    final result = await _loadPage(page, generation: generation);
    if (!_isCurrent(generation)) return;
    final fetched = result.page;
    if (fetched == null) {
      state = state.copyWith(isLoadingMore: false);
      return;
    }
    _merge(fetched.books);
    state = state.copyWith(
      books: List.of(_books),
      hasMore: _hasMoreAfterPage(
        page: page,
        loadedCount: fetched.books.length,
        totalPages: fetched.totalPages ?? state.totalPages,
        effectivePageSize: state.effectivePageSize,
      ),
      nextPage: page + 1,
      totalPages: fetched.totalPages ?? state.totalPages,
      isLoadingMore: false,
    );
  }

  /// Whether another page exists after the page just loaded.
  ///
  /// A known total is authoritative: `page < totalPages`. Without
  /// one, a page is full iff it carried as many cards as the first
  /// page did — a short page is the last one. An empty first page
  /// (`effectivePageSize` 0) has no next page.
  bool _hasMoreAfterPage({
    required int page,
    required int loadedCount,
    required int? totalPages,
    required int? effectivePageSize,
  }) {
    if (totalPages != null) return page < totalPages;
    if (effectivePageSize == null || effectivePageSize <= 0) return false;
    return loadedCount == effectivePageSize;
  }

  /// Loads one page: Dio first, the WebView solver on the
  /// browser-check wall. Returns the page, or null page + an error
  /// message when both paths failed.
  Future<({CategoryPage? page, String? error})> _loadPage(
    int page, {
    required int generation,
  }) async {
    final s = state;
    final inSearch = s.query.isNotEmpty;
    final url = inSearch
        ? _repository.categorySearchUrl(
            categoryId: _categoryId,
            query: s.query,
            exact: s.exact,
            yearFrom: s.yearFrom,
            yearTo: s.yearTo,
            languages: _languageParam(s.language),
            extensions: _extensionParam(s.extension),
            contentTypes: s.contentTypes,
            order: s.order,
            page: page,
          )
        : _repository.categoryPageUrl(
            categoryId: _categoryId,
            page: page,
            order: s.order,
          );
    try {
      final response = inSearch
          ? await _repository.searchInCategory(
              categoryId: _categoryId,
              query: s.query,
              exact: s.exact,
              yearFrom: s.yearFrom,
              yearTo: s.yearTo,
              languages: _languageParam(s.language),
              extensions: _extensionParam(s.extension),
              contentTypes: s.contentTypes,
              order: s.order,
              page: page,
            )
          : await _repository.fetchBooks(
              categoryId: _categoryId,
              page: page,
              order: s.order,
            );
      if (!_isCurrent(generation)) return (page: null, error: null);
      final data = response.data;
      if (response.success && data != null) {
        return (page: data, error: null);
      }
      final error = response.error ?? 'Failed to load category';
      if (_repository.isChallengeError(response.error)) {
        return _loadPageViaSolver(
          url,
          generation: generation,
          originalError: error,
        );
      }
      return (page: null, error: error);
    } catch (e) {
      if (!_isCurrent(generation)) return (page: null, error: null);
      return (page: null, error: e.toString());
    }
  }

  Future<({CategoryPage? page, String? error})> _loadPageViaSolver(
    String url, {
    required int generation,
    required String originalError,
  }) async {
    final user = ref.read(authProvider).user;
    final html = await _repository.fetchViaSolver(
      url,
      userId: user?.id,
      userKey: user?.remixUserkey,
    );
    if (!_isCurrent(generation)) return (page: null, error: null);
    if (html == null) return (page: null, error: originalError);
    final page = _repository.parseBooks(
      html,
      baseUrl: Uri.parse(url).origin,
    );
    if (page == null) return (page: null, error: originalError);
    return (page: page, error: null);
  }

  /// The plugin's `languages` value for a filter key: null (no
  /// filter) for `'all'`, else the single API value.
  List<String>? _languageParam(String language) {
    final apiValue = searchLanguages[language];
    return apiValue == null ? null : [apiValue];
  }

  /// The plugin's `extensions` value for a filter key: null (no
  /// filter) for `'all'`, else the single extension.
  List<String>? _extensionParam(String extension) {
    final apiValue = searchExtensions[extension];
    return apiValue == null ? null : [apiValue];
  }

  void _merge(List<CategoryBook> books) {
    for (final book in books) {
      if (_bookIds.add(book.book.id)) _books.add(book);
    }
  }
}

final categoryBooksControllerProvider = NotifierProvider.autoDispose
    .family<CategoryBooksController, CategoryBooksState, CategoryBooksArgs>(
      CategoryBooksController.new,
    );
