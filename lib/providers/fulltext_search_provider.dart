import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../services/fulltext_repository.dart';
import 'auth_provider.dart';
import 'zlibrary_provider.dart';

// ── Full-text search ────────────────────────────────────────────────

/// Parameters for one full-text search. `yearFrom` / `yearTo` are
/// supported by the plugin but not exposed in the filter UI (v1) —
/// the sheet has no year controls, same as the general search.
class FullTextSearchParams {
  final String query;

  /// `words` （按字搜索， default) or `phrase` （按词搜索）.
  final String type;

  /// `e=1` （精确对应）.
  final bool exact;
  final int? yearFrom;
  final int? yearTo;
  final List<String>? languages;
  final List<String>? extensions;

  /// One of popular / bestmatch / date / titleA / title / year /
  /// filesize / filesizeA. Never sent to the eapi search.
  final String? order;

  const FullTextSearchParams({
    required this.query,
    this.type = 'words',
    this.exact = false,
    this.yearFrom,
    this.yearTo,
    this.languages,
    this.extensions,
    this.order,
  });
}

class FullTextSearchState {
  final List<FullTextHit> hits;

  /// The total from the results tab (`全文检索 (N)`).
  final int total;
  final int currentPage;
  final int totalPages;

  /// True when the next page may exist. Set from the short-page
  /// rule (a page with fewer than 50 hits is the last one) — the
  /// same rule the category pages use. `totalPages` is display-only:
  /// `pagerOptions` is absent on some pages, where it defaults to 1
  /// and must not cut pagination short.
  final bool hasMore;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasSearched;

  /// Raw error string, or null. The screen maps the known
  /// [fulltextTokenUnavailable] value to its localized message.
  final String? error;

  /// True when the search was refused because nobody is signed in
  /// (the token cannot be fetched without a session). The screen
  /// renders the login prompt instead of the error text.
  final bool loginRequired;

  const FullTextSearchState({
    this.hits = const [],
    this.total = 0,
    this.currentPage = 1,
    this.totalPages = 1,
    this.hasMore = true,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasSearched = false,
    this.error,
    this.loginRequired = false,
  });

  FullTextSearchState copyWith({
    List<FullTextHit>? hits,
    int? total,
    int? currentPage,
    int? totalPages,
    bool? hasMore,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasSearched,
    String? error,
    bool clearError = false,
    bool? loginRequired,
  }) {
    return FullTextSearchState(
      hits: hits ?? this.hits,
      total: total ?? this.total,
      currentPage: currentPage ?? this.currentPage,
      totalPages: totalPages ?? this.totalPages,
      hasMore: hasMore ?? this.hasMore,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasSearched: hasSearched ?? this.hasSearched,
      error: clearError ? null : (error ?? this.error),
      loginRequired: loginRequired ?? this.loginRequired,
    );
  }
}

class FullTextSearchNotifier extends Notifier<FullTextSearchState> {
  // Getter, not a `late final` field: ref.invalidate re-runs build()
  // on the SAME notifier instance and a second late-final assignment
  // throws LateInitializationError (same documented pitfall as
  // SearchNotifier above).
  FulltextRepository get _repository =>
      FulltextRepository(ref.read(zlibraryApiProvider));

  FullTextSearchParams? _lastParams;
  int _requestId = 0;

  /// The next page, fetched speculatively while the user reads the
  /// current one. Consumed by loadMore when it matches (same params
  /// instance, page = current + 1); dropped on any new search or
  /// reset. One page ahead only — the cost is bounded at one extra
  /// page download per search, and never started off the solver path
  /// (a walled mirror spends two WebView loads per page; running
  /// those on speculation would hurt more than the prefetch helps).
  ({FullTextSearchParams params, int page, FullTextSearchPage data})?
      _prefetched;

  /// The in-flight prefetch load, so a scroll arriving while it runs
  /// awaits it instead of double-fetching the same page.
  Future<({FullTextSearchPage? page, String? error, bool viaSolver})>?
      _prefetchInFlight;

  /// Generation guard: every new search / reset / consume bumps it,
  /// so a stale prefetch continuation can never write into newer
  /// state.
  int _prefetchGen = 0;

  @override
  FullTextSearchState build() {
    return const FullTextSearchState();
  }

  /// The site renders 50 hits per full-text page.
  static int get pageSize => ZLibraryFullText.fulltextPageSize;

  Future<void> search(FullTextSearchParams params) async {
    final requestId = ++_requestId;
    _lastParams = params;
    _dropPrefetch();
    // The token lives in the signed-in session: without a login
    // there is nothing to fetch it from. Intercept here instead of
    // letting the plugin fail with the generic unavailable error.
    if (ref.read(authProvider).user == null) {
      state = const FullTextSearchState(
        isLoading: false,
        hasSearched: true,
        loginRequired: true,
      );
      return;
    }
    state = const FullTextSearchState(isLoading: true, hasSearched: true);
    final result = await _loadPage(params, 1);
    if (requestId != _requestId) return;
    final page = result.page;
    if (page == null) {
      state = state.copyWith(
        error: result.error ?? 'fulltext search failed',
        isLoading: false,
      );
      return;
    }
    state = FullTextSearchState(
      hits: page.hits,
      total: page.total,
      currentPage: 1,
      totalPages: page.totalPages,
      hasMore: page.hits.length == pageSize,
      hasSearched: true,
    );
    // Seed the next page only off the fast path: the solver path
    // spends two WebView loads per page, never speculatively.
    if (!result.viaSolver && state.hasMore) _startPrefetch(params, 2);
  }

  /// Load-more for page 2 and up. A failed later page must not
  /// silently end the list: a network blip would look like "no more
  /// books" with no way back. Keep the state so the next scroll
  /// event re-enters loadMore and retries.
  ///
  /// A matching prefetch replaces the network load: a finished one
  /// paints at once (no loading flash), an in-flight one is awaited
  /// instead of double-fetching the same page. Anything else falls
  /// through to the normal load, which then seeds the next prefetch.
  Future<void> loadMore() async {
    final s = state;
    final params = _lastParams;
    if (params == null ||
        s.isLoading ||
        s.isLoadingMore ||
        !s.hasMore ||
        s.error != null ||
        s.loginRequired) {
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
      // normal way below (its own error handling and retry rules
      // apply; retrying the dead prefetch future would loop forever).
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
    FullTextSearchParams params,
    int page,
    FullTextSearchPage data,
    int requestId, {
    required bool viaSolver,
  }) {
    if (requestId != _requestId) return;
    final s = state;
    final seen = {for (final hit in s.hits) hit.book.id};
    final merged = List<FullTextHit>.of(s.hits);
    for (final hit in data.hits) {
      if (seen.add(hit.book.id)) merged.add(hit);
    }
    state = s.copyWith(
      hits: merged,
      total: data.total,
      currentPage: page,
      totalPages: data.totalPages,
      hasMore: data.hits.length == pageSize,
      isLoadingMore: false,
    );
    if (!viaSolver && state.hasMore) _startPrefetch(params, page + 1);
  }

  /// Speculatively loads [page] of [params] into [_prefetched]. Fire
  /// and forget: any failure just leaves no prefetch behind, and the
  /// next loadMore fetches that page the normal way.
  void _startPrefetch(FullTextSearchParams params, int page) {
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
    state = const FullTextSearchState();
  }

  /// Loads one page: Dio first, the WebView solver on the
  /// browser-check wall. Returns the page, or null page + an error
  /// message when both paths failed. [viaSolver] says which path
  /// produced a non-null page (the solver path is never prefetched
  /// from).
  Future<({FullTextSearchPage? page, String? error, bool viaSolver})>
      _loadPage(
    FullTextSearchParams params,
    int page,
  ) async {
    try {
      final response = await _repository.search(
        query: params.query,
        type: params.type,
        exact: params.exact,
        yearFrom: params.yearFrom,
        yearTo: params.yearTo,
        languages: params.languages,
        extensions: params.extensions,
        order: params.order,
        page: page,
      );
      final data = response.data;
      if (response.success && data != null) {
        return (page: data, error: null, viaSolver: false);
      }
      final error = response.error ?? 'fulltext search failed';
      if (_repository.isChallengeError(response.error)) {
        // `return await`, not `return`: without the await the
        // try/catch never sees the solver path's failures (an async
        // throw becomes a failed future that flies straight past the
        // catch) — CI-proven 2026-11-13 by the prefetch tests, which
        // were the first to exercise this path in a unit test.
        return await _loadPageViaSolver(
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

  Future<({FullTextSearchPage? page, String? error, bool viaSolver})>
      _loadPageViaSolver(
    FullTextSearchParams params,
    int page, {
    required String originalError,
  }) async {
    final user = ref.read(authProvider).user;
    // On a walled mirror the Dio token fetch in searchFullText never
    // succeeds, so the cached token is null and a tokenless solver
    // URL answers with the default 50-book listing — the query
    // echoes, the wrong-page guard passes, and the app paints the
    // same fixed set for any query (device-proven 2026-11-11). Fetch
    // the bare /fulltext token page through the solver first (same
    // origin, same session) and read the token from its form; the
    // search URL below is built with that token. A missing token
    // page or a page with no token fails exactly like a failed
    // solve — a tokenless result is never painted.
    final tokenHtml = await _repository.fetchViaSolver(
      _repository.tokenPageUrl(),
      userId: user?.id,
      userKey: user?.remixUserkey,
    );
    final token =
        tokenHtml == null ? null : extractFulltextToken(tokenHtml);
    if (token == null) {
      return (page: null, error: originalError, viaSolver: true);
    }
    final url = _repository.searchPageUrl(
      query: params.query,
      type: params.type,
      exact: params.exact,
      yearFrom: params.yearFrom,
      yearTo: params.yearTo,
      languages: params.languages,
      extensions: params.extensions,
      order: params.order,
      page: page,
      token: token,
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

final fulltextSearchProvider =
    NotifierProvider<FullTextSearchNotifier, FullTextSearchState>(
      FullTextSearchNotifier.new,
    );
