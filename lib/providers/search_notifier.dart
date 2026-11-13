// Split out of `books_provider.dart` (M3): search state + SearchNotifier + searchProvider.
// `books_provider.dart` re-exports this file, so existing
// imports of `package:zlibx/providers/books_provider.dart` keep working.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../services/category_repository.dart';
import 'auth_provider.dart';
import 'zlibrary_provider.dart';

// ── Search ──────────────────────────────────────────────────────────

class SearchParams {
  final String? query;
  final int? yearFrom;
  final int? yearTo;
  final List<String>? languages;
  final List<String>? extensions;
  final String? order;
  final int limit;

  /// Exact title match (sends `e=1` to /eapi/book/search).
  final bool exact;

  /// Category scope (general mode only): when set, the request goes
  /// to the category HTML routes instead of the eapi search — browse
  /// when [query] is empty, in-category search otherwise.
  final int? categoryId;

  /// Content-type filter for in-category search (`book` / `article`);
  /// only sent on the category path.
  final List<String>? contentTypes;

  SearchParams({
    this.query,
    this.yearFrom,
    this.yearTo,
    this.languages,
    this.extensions,
    this.order,
    this.limit = 20,
    this.exact = false,
    this.categoryId,
    this.contentTypes,
  });
}

class SearchState {
  final List<Book> books;
  final int currentPage;
  final int totalPages;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasSearched;
  final String? error;

  /// True when the current total is unknown: the category page
  /// carried no `pagerOptions` total, so [totalPages] is a sentinel
  /// that keeps paging alive until a short page arrives. The screen
  /// shows an ellipsis instead of the number in that case.
  final bool totalPagesUnknown;

  /// Per-card unavailability from the category pages (book id to
  /// reason, `'copyright'` / `'removed'`): the search result cards
  /// carry no such flag, so it rides alongside the books and the
  /// screen passes it to the detail page, which blocks the download
  /// button for those books. Empty for non-category searches.
  final Map<int, String> unavailableReasons;

  const SearchState({
    this.books = const [],
    this.currentPage = 1,
    this.totalPages = 1,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasSearched = false,
    this.error,
    this.totalPagesUnknown = false,
    this.unavailableReasons = const {},
  });

  SearchState copyWith({
    List<Book>? books,
    int? currentPage,
    int? totalPages,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasSearched,
    String? error,
    bool? totalPagesUnknown,
    Map<int, String>? unavailableReasons,
  }) {
    return SearchState(
      books: books ?? this.books,
      currentPage: currentPage ?? this.currentPage,
      totalPages: totalPages ?? this.totalPages,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasSearched: hasSearched ?? this.hasSearched,
      error: error,
      totalPagesUnknown: totalPagesUnknown ?? this.totalPagesUnknown,
      unavailableReasons: unavailableReasons ?? this.unavailableReasons,
    );
  }
}

class SearchNotifier extends Notifier<SearchState> {
  // Getter, not a `late final` field: ref.invalidate re-runs build() on
  // the SAME notifier instance and a second late-final assignment throws
  // LateInitializationError (same documented pitfall as
  // SavedBooksNotifier below).
  ZLibraryApi get _api => ref.read(zlibraryApiProvider);
  SearchParams? _lastParams;
  int _requestId = 0;

  /// Sentinel total while a category list's real total is unknown
  /// (its page carried no `pagerOptions` total): large enough that
  /// [loadMore]'s `currentPage >= totalPages` guard never stops the
  /// list early; the real total replaces it when a short page
  /// arrives. Never displayed — the screen shows an ellipsis while
  /// [SearchState.totalPagesUnknown] is true.
  static const int _unknownTotalPages = 1000000;

  /// First page's card count of the current category list, the
  /// effective page size when the page carries no total (the old
  /// category controller's rule). Reset on every new search.
  int? _categoryPageSize;

  /// Search-form slugs per category id, for the in-category search
  /// URL (see `_resolveCategorySlug`). The slug comes from the
  /// category page's search form, never hand-built.
  final Map<int, String> _categorySearchSlugs = {};

  @override
  SearchState build() {
    return const SearchState();
  }

  /// 统一取数入口，search / loadMore 共用。
  Future<ApiResponse<List<Book>>> _fetch(SearchParams params, int page) async {
    final categoryId = params.categoryId;
    if (categoryId != null) {
      return _fetchCategory(params, categoryId, page);
    }
    return _api.search(
      message: params.query,
      yearFrom: params.yearFrom,
      yearTo: params.yearTo,
      languages: params.languages,
      extensions: params.extensions,
      order: params.order,
      page: page,
      limit: params.limit,
      exact: params.exact,
    );
  }

  /// The slug for [categoryId]'s search URL, from the browse page's
  /// search form (cached). Resolves by browsing (fast Dio first,
  /// the WebView solver on the wall) when nothing is cached yet;
  /// null when the browse fails — the caller treats that as an
  /// error, never a bare-URL fallback (the bare search URL answers
  /// an empty page). Never throws.
  Future<String?> _resolveCategorySlug(int categoryId) async {
    final cached = _categorySearchSlugs[categoryId];
    if (cached != null && cached.isNotEmpty) return cached;
    try {
      final repo = CategoryRepository(_api);
      var response = await repo.fetchBooks(categoryId: categoryId, page: 1);
      if (!response.success && repo.isChallengeError(response.error)) {
        final user = ref.read(authProvider).user;
        final browseUrl =
            repo.categoryPageUrl(categoryId: categoryId, page: 1);
        final html = await repo.fetchViaSolver(
          browseUrl,
          userId: user?.id,
          userKey: user?.remixUserkey,
        );
        if (html != null) {
          final parsed = repo.parseBooks(
            html,
            baseUrl: Uri.parse(browseUrl).origin,
          );
          if (parsed != null) {
            response = ApiResponse.ok(parsed);
          }
        }
      }
      final slug = response.data?.searchSlug;
      if (slug != null && slug.isNotEmpty) {
        _categorySearchSlugs[categoryId] = slug;
      }
      return slug;
    } catch (_) {
      return null;
    }
  }

  /// One page of a category browse/search, mapped onto the search
  /// result shape: the category page's books as plain [Book]s — the
  /// per-card unavailability rides in the response meta (see
  /// [SearchState.unavailableReasons]) — plus its page count.
  ///
  /// Empty query browses the category (`getCategoryBooks`, order
  /// only); a query searches inside it (`searchInCategory`, with the
  /// same filters the old category controller passed: exact, years,
  /// languages, extensions, content types, order). A browser-check
  /// wall escalates to the WebView solver exactly like the old
  /// controller's load path; a failed solve keeps the original
  /// failure, never an invented page.
  ///
  /// Total pages: the page's `pagerOptions` total when present. A
  /// small category's page carries none, so the first page's card
  /// count becomes the effective page size and the total stays
  /// unknown until a short page arrives (a page shorter than the
  /// first is the last one).
  Future<ApiResponse<List<Book>>> _fetchCategory(
    SearchParams params,
    int categoryId,
    int page,
  ) async {
    final query = params.query?.trim() ?? '';
    final inSearch = query.isNotEmpty;
    final repo = CategoryRepository(_api);
    // The in-category search only works at the slugged URL
    // (`/category/{id}/{slug}/s/`); the bare `/category/{id}/s/`
    // answers an empty page (device-proven 2026-11-12: the solver
    // loaded the bare URL and parsed 0 cards). Resolve the slug
    // from the browse page's search form (cached per category).
    // A failed resolve is a retryable error, not an empty result:
    // never fall back to the bare URL — it would answer an empty
    // page and the search would look like it found nothing.
    final slug = inSearch ? await _resolveCategorySlug(categoryId) : null;
    if (inSearch && slug == null) {
      return ApiResponse.fail(
        'Failed to load the category search address. Please retry.',
      );
    }
    final url = inSearch
        ? repo.categorySearchUrl(
            categoryId: categoryId,
            slug: slug,
            query: query,
            exact: params.exact,
            yearFrom: params.yearFrom,
            yearTo: params.yearTo,
            languages: params.languages,
            extensions: params.extensions,
            contentTypes: params.contentTypes,
            order: params.order,
            page: page,
          )
        : repo.categoryPageUrl(
            categoryId: categoryId,
            page: page,
            order: params.order,
          );
    ApiResponse<CategoryPage> response;
    try {
      response = inSearch
          ? await repo.searchInCategory(
              categoryId: categoryId,
              slug: slug,
              query: query,
              exact: params.exact,
              yearFrom: params.yearFrom,
              yearTo: params.yearTo,
              languages: params.languages,
              extensions: params.extensions,
              contentTypes: params.contentTypes,
              order: params.order,
              page: page,
            )
          : await repo.fetchBooks(
              categoryId: categoryId,
              page: page,
              order: params.order,
            );
    } catch (e) {
      return ApiResponse.fail(e.toString());
    }
    if (!response.success && repo.isChallengeError(response.error)) {
      final user = ref.read(authProvider).user;
      final html = await repo.fetchViaSolver(
        url,
        userId: user?.id,
        userKey: user?.remixUserkey,
      );
      if (html != null) {
        final parsed = repo.parseBooks(html, baseUrl: Uri.parse(url).origin);
        if (parsed != null) {
          response = ApiResponse.ok(parsed);
        }
      }
    }
    final data = response.data;
    if (!response.success || data == null) {
      return ApiResponse.fail(response.error ?? 'Failed to load category');
    }
    // Keep the page's search-form slug for later searches in this
    // category (a browse result carries it too).
    final pageSlug = data.searchSlug;
    if (pageSlug != null && pageSlug.isNotEmpty) {
      _categorySearchSlugs[categoryId] = pageSlug;
    }
    final books = <Book>[];
    final unavailable = <int, String>{};
    for (final item in data.books) {
      books.add(item.book);
      final reason = item.unavailableReason;
      if (reason != null) unavailable[item.book.id] = reason;
    }
    final total = data.totalPages;
    final int totalPages;
    final bool unknown;
    if (total != null) {
      totalPages = total;
      unknown = false;
    } else if (page == 1) {
      if (books.isEmpty) {
        totalPages = 1;
        unknown = false;
      } else {
        _categoryPageSize = books.length;
        totalPages = _unknownTotalPages;
        unknown = true;
      }
    } else if (_categoryPageSize == null ||
        books.length < _categoryPageSize!) {
      // Short page (or no recorded size): this is the last page.
      totalPages = page;
      unknown = false;
    } else {
      totalPages = _unknownTotalPages;
      unknown = true;
    }
    return ApiResponse.ok(
      books,
      meta: {
        'total_pages': totalPages,
        'total_pages_unknown': unknown,
        'unavailable_reasons': unavailable,
      },
    );
  }

  /// The category page's per-card unavailability out of a fetch
  /// response's meta (empty for non-category searches).
  Map<int, String> _unavailableReasonsOf(ApiResponse<List<Book>> response) {
    final raw = response.meta?['unavailable_reasons'];
    if (raw is Map<int, String>) return Map.of(raw);
    if (raw is Map) {
      final out = <int, String>{};
      for (final entry in raw.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is int && value is String) out[key] = value;
      }
      return out;
    }
    return const {};
  }

  Future<void> search(SearchParams params) async {
    final requestId = ++_requestId;
    _lastParams = params;
    _categoryPageSize = null;
    state = const SearchState(isLoading: true, hasSearched: true);

    try {
      final response = await _fetch(params, 1);
      if (requestId != _requestId) return;
      if (!response.success) {
        throw StateError(response.error ?? 'Search failed');
      }

      final totalPages = response.meta?['total_pages'] ?? 1;
      state = SearchState(
        books: response.data ?? [],
        currentPage: 1,
        totalPages: totalPages is int ? totalPages : 1,
        totalPagesUnknown: response.meta?['total_pages_unknown'] == true,
        unavailableReasons: _unavailableReasonsOf(response),
        hasSearched: true,
      );
    } catch (e) {
      if (requestId != _requestId) return;
      state = SearchState(hasSearched: true, error: e.toString());
    }
  }

  Future<void> loadMore() async {
    if (_lastParams == null ||
        state.isLoadingMore ||
        state.currentPage >= state.totalPages) {
      return;
    }

    final nextPage = state.currentPage + 1;
    final requestId = _requestId;
    state = state.copyWith(isLoadingMore: true);

    try {
      final response = await _fetch(_lastParams!, nextPage);
      if (requestId != _requestId) return;
      if (!response.success) {
        throw StateError(response.error ?? 'Search failed');
      }

      final totalPages = response.meta?['total_pages'];
      state = state.copyWith(
        books: [...state.books, ...response.data ?? []],
        currentPage: nextPage,
        totalPages: totalPages is int ? totalPages : state.totalPages,
        totalPagesUnknown: response.meta?['total_pages_unknown'] == true,
        unavailableReasons: {
          ...state.unavailableReasons,
          ..._unavailableReasonsOf(response),
        },
        isLoadingMore: false,
      );
    } catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(isLoadingMore: false, error: e.toString());
    }
  }

  void reset() {
    _requestId++;
    _lastParams = null;
    _categoryPageSize = null;
    state = const SearchState();
  }
}

final searchProvider =
    NotifierProvider<SearchNotifier, SearchState>(SearchNotifier.new);
