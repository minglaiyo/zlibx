// Split out of `books_provider.dart` (M3): search state + SearchNotifier + searchProvider.
// `books_provider.dart` re-exports this file, so existing
// imports of `package:zlibx/providers/books_provider.dart` keep working.

import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../constants/search_filters.dart';
import '../services/category_repository.dart';
import '../services/search_html_repository.dart';
import '../utils/blocked_keywords.dart';
import 'auth_provider.dart';
import 'settings_provider.dart';
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

  /// Field the query is scoped to (detail-page author/publisher
  /// tap). The eapi search has no server-side field parameter (its
  /// `message` matches every field), so the returned books are
  /// filtered client-side; null = unscoped general search.
  final SearchField? field;

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
    this.field,
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

  /// Live cancel token of the current search session, shared by
  /// [search]'s first page and [loadMore]'s follow-ups: a new search
  /// cancels the previous session's in-flight request instead of
  /// letting it run to completion only for its result to be discarded
  /// by the [_requestId] guard. The eapi search path honours the
  /// token (plugin `search(cancelToken:)`); the category HTML path
  /// relies on the guard alone.
  CancelToken? _searchToken;

  /// Sentinel total while a category list's real total is unknown
  /// (its page carried no `pagerOptions` total): large enough that
  /// [loadMore]'s `currentPage >= totalPages` guard never stops the
  /// list early; the real total replaces it when a short page
  /// arrives. Never displayed — the screen shows an ellipsis while
  /// [SearchState.totalPagesUnknown] is true.
  static const int _unknownTotalPages = 1000000;

  /// Pager math shared by the two HTML listing paths (category and
  /// book search). A page that carries its own `pagerOptions` count
  /// is authoritative. Without one the page size is unknown, so the
  /// list must not stop early: [recordedPageSize] (the first page's
  /// card count, kept per path by the caller) decides whether a short
  /// page means "last page". Returns the effective [pageSize] for the
  /// caller to store — the callers keep separate fields so a session
  /// that switches channels never inherits the other's page size.
  static ({int totalPages, bool unknown, int? pageSize}) _pagination({
    required int? totalPagesFromPage,
    required int page,
    required int bookCount,
    required int? recordedPageSize,
  }) {
    if (totalPagesFromPage != null) {
      return (
        totalPages: totalPagesFromPage,
        unknown: false,
        pageSize: recordedPageSize,
      );
    }
    if (page == 1) {
      if (bookCount == 0) {
        return (
          totalPages: 1,
          unknown: false,
          pageSize: recordedPageSize,
        );
      }
      return (
        totalPages: _unknownTotalPages,
        unknown: true,
        pageSize: bookCount,
      );
    }
    if (recordedPageSize == null || bookCount < recordedPageSize) {
      // Short page (or no recorded size): this is the last page.
      return (
        totalPages: page,
        unknown: false,
        pageSize: recordedPageSize,
      );
    }
    return (
      totalPages: _unknownTotalPages,
      unknown: true,
      pageSize: recordedPageSize,
    );
  }

  /// First page's card count of the current category list, the
  /// effective page size when the page carries no total (the old
  /// category controller's rule). Reset on every new search.
  int? _categoryPageSize;

  /// First page's card count of the current HTML book search, used
  /// the same way as [_categoryPageSize] when the results page
  /// carries no `pagerOptions` count. Kept separate so a session that
  /// falls back mid-way never inherits the category path's size.
  /// Reset on every new search.
  int? _htmlSearchPageSize;

  /// Search-form slugs per category id, for the in-category search
  /// URL (see `_resolveCategorySlug`). The slug comes from the
  /// category page's search form, never hand-built.
  final Map<int, String> _categorySearchSlugs = {};

  @override
  SearchState build() {
    return const SearchState();
  }

  /// 统一取数入口，search / loadMore 共用。
  Future<ApiResponse<List<Book>>> _fetch(
    SearchParams params,
    int page,
    CancelToken? cancelToken,
  ) async {
    final categoryId = params.categoryId;
    if (categoryId != null) {
      return _fetchCategory(params, categoryId, page, cancelToken);
    }
    final response = await _api.search(
      message: params.query,
      yearFrom: params.yearFrom,
      yearTo: params.yearTo,
      languages: params.languages,
      extensions: params.extensions,
      order: params.order,
      page: page,
      limit: params.limit,
      exact: params.exact,
      cancelToken: cancelToken,
    );
    if (response.success && response.data != null) {
      return ApiResponse.ok(
        _filterByField(response.data!, params.field, params.query ?? ''),
        meta: response.meta,
      );
    }
    // The eapi search is the primary channel, but as of 2026-11-23 it
    // answers `400 Access denied` on every mirror, which would leave
    // the app with no search at all. The site's own HTML results page
    // still answers, so an eapi failure falls through to it instead
    // of surfacing as a dead search. A superseded request does NOT
    // fall through: the plugin reports a cancel as an error value
    // rather than a throw, so the guard has to be here.
    if (response.error == 'cancelled' || cancelToken?.isCancelled == true) {
      return response;
    }
    return _fetchBooksHtml(
      params,
      page,
      cancelToken,
      originalError: response.error ?? 'Search failed',
    );
  }

  /// One page of the HTML book search (`/s/{query}`): plain Dio
  /// first, the WebView solver on the browser-check wall — the same
  /// two-step the article, category and full-text screens use, with
  /// [SearchHtmlRepository] as the plumbing.
  ///
  /// [originalError] is the eapi failure that sent us here. It is
  /// what the caller sees when the HTML channel also comes back
  /// empty-handed (wall unsolved, page unparseable), so a fallback
  /// that silently produced nothing never looks like "no results".
  ///
  /// Note the page size: the HTML route has no `limit` parameter and
  /// renders the site's own ~51 cards, so `params.limit` is not
  /// applied here. Pagination still works because `pagerOptions`
  /// counts pages at that same size.
  Future<ApiResponse<List<Book>>> _fetchBooksHtml(
    SearchParams params,
    int page,
    CancelToken? cancelToken, {
    required String originalError,
  }) async {
    final query = params.query?.trim() ?? '';
    if (query.isEmpty) return ApiResponse.fail(originalError);
    final repo = SearchHtmlRepository(_api);
    ApiResponse<BookSearchPage> response;
    try {
      response = await repo.search(
        query: query,
        order: params.order,
        page: page,
        languages: params.languages,
        extensions: params.extensions,
        yearFrom: params.yearFrom,
        yearTo: params.yearTo,
        exact: params.exact,
        cancelToken: cancelToken,
      );
    } on Object catch (e) {
      return ApiResponse.fail(e.toString());
    }
    if (!response.success && repo.isChallengeError(response.error)) {
      final url = repo.searchPageUrl(
        query: query,
        order: params.order,
        page: page,
        languages: params.languages,
        extensions: params.extensions,
        yearFrom: params.yearFrom,
        yearTo: params.yearTo,
        exact: params.exact,
      );
      final user = ref.read(authProvider).user;
      final html = await repo.fetchViaSolver(
        url,
        userId: user?.id,
        userKey: user?.remixUserkey,
      );
      if (html != null) {
        final parsed = await repo.parsePage(
          html,
          baseUrl: Uri.parse(url).origin,
          expectedQuery: query,
        );
        if (parsed != null) response = ApiResponse.ok(parsed);
      }
    }
    final data = response.data;
    if (!response.success || data == null) {
      return ApiResponse.fail(response.error ?? originalError);
    }
    final pagination = _pagination(
      totalPagesFromPage: data.totalPages,
      page: page,
      bookCount: data.books.length,
      recordedPageSize: _htmlSearchPageSize,
    );
    _htmlSearchPageSize = pagination.pageSize;
    return ApiResponse.ok(
      _filterByField(data.books, params.field, query),
      meta: {
        'total_pages': pagination.totalPages,
        'total_pages_unknown': pagination.unknown,
        'unavailable_reasons': data.unavailableReasons,
      },
    );
  }

  /// Client-side field scoping for the eapi search: the endpoint's
  /// `message` matches every field, so a detail-page author/publisher
  /// tap (which carries [SearchField]) filters the returned books down
  /// to those whose author/publisher actually contains the query.
  /// Applied per page, so pagination keeps the scope. The site's own
  /// total page count is kept as-is: the scope can only reduce what is
  /// shown, never the server's paging.
  static List<Book> _filterByField(
    List<Book> books,
    SearchField? field,
    String query,
  ) {
    if (field == null || query.trim().isEmpty) return books;
    final needle = query.trim().toLowerCase();
    return books.where((book) {
      final value = switch (field) {
        SearchField.author => book.author,
        SearchField.publisher => book.publisher,
      };
      return value != null && value.toLowerCase().contains(needle);
    }).toList();
  }

  /// Append [incoming] to [existing], dropping books already present
  /// (same [Book.id]): the site's result window shifts between page
  /// fetches and duplicates would otherwise render as repeated cards.
  List<Book> _mergeBooks(List<Book> existing, List<Book> incoming) {
    final merged = List.of(existing);
    final seen = {for (final book in merged) book.id};
    for (final book in incoming) {
      if (seen.add(book.id)) merged.add(book);
    }
    return merged;
  }

  /// Drop books the user's blocklist hides: any blocked keyword in the
  /// title, author or publisher. Applies to new searches only — the
  /// list is read when a page lands, not re-applied to results already
  /// on screen.
  List<Book> _filterBlocked(List<Book> books) {
    final blocked = ref.read(blockedKeywordsProvider);
    if (blocked.isEmpty) return books;
    return books
        .where(
          (book) => !isBlockedByKeywords(
            title: book.title,
            author: book.author,
            publisher: book.publisher,
            keywords: blocked,
          ),
        )
        .toList();
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
        final browseUrl = repo.categoryPageUrl(categoryId: categoryId, page: 1);
        final html = await repo.fetchViaSolver(
          browseUrl,
          userId: user?.id,
          userKey: user?.remixUserkey,
        );
        if (html != null) {
          final parsed = await repo.parseBooks(
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
    CancelToken? cancelToken,
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
              cancelToken: cancelToken,
            )
          : await repo.fetchBooks(
              categoryId: categoryId,
              page: page,
              order: params.order,
              cancelToken: cancelToken,
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
        final parsed = await repo.parseBooks(
          html,
          baseUrl: Uri.parse(url).origin,
        );
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
    final pagination = _pagination(
      totalPagesFromPage: data.totalPages,
      page: page,
      bookCount: books.length,
      recordedPageSize: _categoryPageSize,
    );
    _categoryPageSize = pagination.pageSize;
    final totalPages = pagination.totalPages;
    final unknown = pagination.unknown;
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
    _htmlSearchPageSize = null;
    // Kill the previous session's in-flight page (no-op when it has
    // already completed) before opening a new token for this one.
    _searchToken?.cancel();
    _searchToken = CancelToken();
    state = const SearchState(isLoading: true, hasSearched: true);

    try {
      final response = await _fetch(params, 1, _searchToken);
      if (requestId != _requestId) return;
      if (!response.success) {
        throw StateError(response.error ?? 'Search failed');
      }

      final totalPages = response.meta?['total_pages'] ?? 1;
      final books = response.data ?? const <Book>[];
      state = SearchState(
        books: _filterBlocked(_mergeBooks(const [], books)),
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
      final response = await _fetch(_lastParams!, nextPage, _searchToken);
      if (requestId != _requestId) return;
      if (!response.success) {
        throw StateError(response.error ?? 'Search failed');
      }

      final totalPages = response.meta?['total_pages'];
      state = state.copyWith(
        books: _filterBlocked(
          _mergeBooks(state.books, response.data ?? const <Book>[]),
        ),
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
    _htmlSearchPageSize = null;
    _searchToken?.cancel();
    _searchToken = null;
    state = const SearchState();
  }
}

final searchProvider = NotifierProvider<SearchNotifier, SearchState>(
  SearchNotifier.new,
);
