import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../services/article_repository.dart';
import 'auth_provider.dart';
import 'zlibrary_provider.dart';

// ── Article search ──────────────────────────────────────────────────

/// Parameters for one article search. Language / extension filters
/// are NOT here (v1): the plugin's searchArticles does not send them
/// until their `/s/` parameter names are device-verified, and the
/// search screen hides those filter sections in article mode so the
/// UI can never promise a filter the request does not carry. [order]
/// is the general sort map's value, passed through as-is.
class ArticleSearchParams {
  final String query;
  final String? order;

  const ArticleSearchParams({required this.query, this.order});
}

class ArticleSearchState {
  final List<Article> articles;

  /// The total from the results tab (`文章 (N)`).
  final int total;
  final int currentPage;
  final int totalPages;

  /// True when the next page may exist. The `/s/` article page size
  /// is not device-verified (the 2026-11-11 capture has a single
  /// page and renders no pager data), so unlike full-text search the
  /// short-page rule is not available; the rule here combines the
  /// two signals a page does carry: the tab total (merged list
  /// shorter than the total) and the `pagerOptions.pagesTotal`
  /// script (more pages than the current one). Either saying "more"
  /// keeps the list open; a page with neither and a full merge ends
  /// it.
  final bool hasMore;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasSearched;

  /// Raw error string, or null. The screen renders it like the
  /// general search's error (no special-case mapping yet — the
  /// plugin's article errors are plain strings).
  final String? error;

  const ArticleSearchState({
    this.articles = const [],
    this.total = 0,
    this.currentPage = 1,
    this.totalPages = 1,
    this.hasMore = true,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasSearched = false,
    this.error,
  });

  ArticleSearchState copyWith({
    List<Article>? articles,
    int? total,
    int? currentPage,
    int? totalPages,
    bool? hasMore,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasSearched,
    String? error,
    bool clearError = false,
  }) {
    return ArticleSearchState(
      articles: articles ?? this.articles,
      total: total ?? this.total,
      currentPage: currentPage ?? this.currentPage,
      totalPages: totalPages ?? this.totalPages,
      hasMore: hasMore ?? this.hasMore,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasSearched: hasSearched ?? this.hasSearched,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ArticleSearchNotifier extends Notifier<ArticleSearchState> {
  // Getter, not a `late final` field: ref.invalidate re-runs build()
  // on the SAME notifier instance and a second late-final assignment
  // throws LateInitializationError (same documented pitfall as the
  // full-text notifier).
  ArticleRepository get _repository =>
      ArticleRepository(ref.read(zlibraryApiProvider));

  ArticleSearchParams? _lastParams;
  int _requestId = 0;

  /// The next page, fetched speculatively while the user reads the
  /// current one. Consumed by loadMore when it matches (same params
  /// instance, page = current + 1); dropped on any new search or
  /// reset. One page ahead only — the cost is bounded at one extra
  /// page download per search, and never started off the solver path
  /// (a walled mirror spends a WebView load per page; running those
  /// on speculation would hurt more than the prefetch helps).
  ({ArticleSearchParams params, int page, ArticleSearchPage data})?
      _prefetched;

  /// The in-flight prefetch load, so a scroll arriving while it runs
  /// awaits it instead of double-fetching the same page.
  Future<({ArticleSearchPage? page, String? error, bool viaSolver})>?
      _prefetchInFlight;

  /// Generation guard: every new search / reset / consume bumps it,
  /// so a stale prefetch continuation can never write into newer
  /// state.
  int _prefetchGen = 0;

  @override
  ArticleSearchState build() {
    return const ArticleSearchState();
  }

  Future<void> search(ArticleSearchParams params) async {
    final requestId = ++_requestId;
    _lastParams = params;
    _dropPrefetch();
    state = const ArticleSearchState(isLoading: true, hasSearched: true);
    final result = await _loadPage(params, 1);
    if (requestId != _requestId) return;
    final page = result.page;
    if (page == null) {
      state = state.copyWith(
        error: result.error ?? 'article search failed',
        isLoading: false,
      );
      return;
    }
    state = ArticleSearchState(
      articles: page.articles,
      total: page.total,
      currentPage: 1,
      totalPages: page.totalPages,
      hasMore: page.articles.isNotEmpty &&
          (page.articles.length < page.total || page.totalPages > 1),
      hasSearched: true,
    );
    // Seed the next page only off the fast path: the solver path
    // spends a WebView load per page, never speculatively.
    if (!result.viaSolver && state.hasMore) _startPrefetch(params, 2);
  }

  /// Load-more for page 2 and up. Same contract as the full-text
  /// notifier: a failed later page keeps the state so the next scroll
  /// event re-enters loadMore and retries. A matching prefetch
  /// replaces the network load: a finished one paints at once (no
  /// loading flash), an in-flight one is awaited instead of
  /// double-fetching the same page. Anything else falls through to
  /// the normal load, which then seeds the next prefetch.
  Future<void> loadMore() async {
    final s = state;
    final params = _lastParams;
    if (params == null ||
        s.isLoading ||
        s.isLoadingMore ||
        !s.hasMore ||
        s.error != null) {
      return;
    }
    final page = s.currentPage + 1;
    final requestId = _requestId;

    final pre = _prefetched;
    if (pre != null && identical(pre.params, params) && pre.page == page) {
      _dropPrefetch();
      state = s.copyWith(isLoadingMore: true);
      _applyLoadedPage(params, page, pre.data, requestId, viaSolver: false);
      return;
    }
    final inFlight = _prefetchInFlight;
    if (inFlight != null) {
      state = s.copyWith(isLoadingMore: true);
      final result = await inFlight;
      if (requestId != _requestId) return;
      if (result.page != null) {
        _dropPrefetch();
        _applyLoadedPage(params, page, result.page!, requestId,
            viaSolver: result.viaSolver);
        return;
      }
      // The speculative load failed — drop it and load the page the
      // normal way below (its own error handling applies; retrying
      // the dead prefetch future would loop forever).
      _dropPrefetch();
      state = state.copyWith(isLoadingMore: false);
    }

    state = state.copyWith(isLoadingMore: true);
    final result = await _loadPage(params, page);
    if (requestId != _requestId) return;
    if (result.page == null) {
      state = state.copyWith(isLoadingMore: false);
      return;
    }
    _dropPrefetch();
    _applyLoadedPage(params, page, result.page!, requestId,
        viaSolver: result.viaSolver);
  }

  /// Merges [data] (page [page] of [params]) into the list, then
  /// seeds the next prefetch when more pages may exist and the fast
  /// Dio path produced this one. The requestId guard is re-checked
  /// here so a consumed prefetch cannot outlive a newer search.
  void _applyLoadedPage(
    ArticleSearchParams params,
    int page,
    ArticleSearchPage data,
    int requestId, {
    required bool viaSolver,
  }) {
    if (requestId != _requestId) return;
    final s = state;
    final seen = {for (final article in s.articles) article.id};
    final merged = List<Article>.of(s.articles);
    for (final article in data.articles) {
      if (seen.add(article.id)) merged.add(article);
    }
    state = s.copyWith(
      articles: merged,
      total: data.total,
      currentPage: page,
      totalPages: data.totalPages,
      hasMore: data.articles.isNotEmpty &&
          (merged.length < data.total || data.totalPages > page),
      isLoadingMore: false,
    );
    if (!viaSolver && state.hasMore) _startPrefetch(params, page + 1);
  }

  /// Speculatively loads [page] of [params] into [_prefetched]. Fire
  /// and forget: any failure just leaves no prefetch behind, and the
  /// next loadMore fetches that page the normal way.
  void _startPrefetch(ArticleSearchParams params, int page) {
    final gen = _prefetchGen;
    _prefetched = null;
    final future = _loadPage(params, page);
    _prefetchInFlight = future;
    unawaited(future.then((result) {
      if (gen != _prefetchGen) return;
      _prefetchInFlight = null;
      final data = result.page;
      if (data == null || result.viaSolver) return;
      _prefetched = (params: params, page: page, data: data);
    }));
  }

  /// Drops any parked / in-flight prefetch and invalidates its
  /// continuation (the load itself, if running, is left to finish —
  /// its result is discarded by the generation check).
  void _dropPrefetch() {
    _prefetched = null;
    _prefetchInFlight = null;
    _prefetchGen++;
  }

  void reset() {
    _lastParams = null;
    _dropPrefetch();
    state = const ArticleSearchState();
  }

  /// Loads one page: Dio first, the WebView solver on the
  /// browser-check wall. Returns the page, or null page + an error
  /// message when both paths failed. [viaSolver] says which path
  /// produced a non-null page (the solver path is never prefetched
  /// from).
  Future<({ArticleSearchPage? page, String? error, bool viaSolver})>
      _loadPage(
    ArticleSearchParams params,
    int page,
  ) async {
    try {
      final response = await _repository.search(
        query: params.query,
        order: params.order,
        page: page,
      );
      final data = response.data;
      if (response.success && data != null) {
        return (page: data, error: null, viaSolver: false);
      }
      final error = response.error ?? 'article search failed';
      if (_repository.isChallengeError(response.error)) {
        return _loadPageViaSolver(
          params,
          page,
          originalError: error,
        );
      }
      return (page: null, error: error, viaSolver: false);
    } catch (e) {
      return (page: null, error: e.toString(), viaSolver: false);
    }
  }

  /// WebView-solver fallback. Simpler than the full-text one: the
  /// `/s/` route needs no session token, so the solver goes straight
  /// to the results URL (the session cookies are installed inside
  /// fetchViaSolver when the user is signed in).
  Future<({ArticleSearchPage? page, String? error, bool viaSolver})>
      _loadPageViaSolver(
    ArticleSearchParams params,
    int page, {
    required String originalError,
  }) async {
    final user = ref.read(authProvider).user;
    final url = _repository.searchPageUrl(
      query: params.query,
      order: params.order,
      page: page,
    );
    final html = await _repository.fetchViaSolver(
      url,
      userId: user?.id,
      userKey: user?.remixUserkey,
    );
    if (html == null) {
      return (page: null, error: originalError, viaSolver: true);
    }
    final parsed = _repository.parsePage(
      html,
      baseUrl: Uri.parse(url).origin,
      expectedQuery: params.query,
    );
    if (parsed == null) {
      return (page: null, error: originalError, viaSolver: true);
    }
    return (page: parsed, error: null, viaSolver: true);
  }
}

final articleSearchProvider =
    NotifierProvider<ArticleSearchNotifier, ArticleSearchState>(
      ArticleSearchNotifier.new,
    );
