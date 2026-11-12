import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/utils/diagnostics.dart';
import '../models/display_book.dart';
import '../services/annas_archieve.dart';
import '../services/book_detail_page_repository.dart';
import '../services/category_repository.dart';
import '../services/download_stats_repository.dart';
import '../services/external_search.dart';
import '../services/libgen_service.dart';
import '../services/network_error.dart';
import '../services/storage_service.dart';
import '../utils/app_log.dart';
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
  /// null when the browse fails, in which case the caller falls
  /// back to the bare search URL. Never throws.
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
    // from the browse page's search form (cached per category);
    // null falls back to the bare URL.
    final slug = inSearch ? await _resolveCategorySlug(categoryId) : null;
    // Temporary diagnostic (category search, 2026-11-12): whether
    // the slug resolved. Release-safe: a public category slug only.
    if (inSearch) {
      AppLog.report(
        'category slug cat=$categoryId slug=${slug ?? 'none'}',
        tag: 'category-search',
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
    // Temporary diagnostic (category search, 2026-11-12): the direct
    // fetch 503s (browser-check wall) and the solver is the only path
    // to results. Log whether it ran and what it returned, so the next
    // log shows whether the solver itself is the bottleneck.
    // Release-safe: counts only.
    var solverRan = false;
    int? solverParsed;
    if (!response.success && repo.isChallengeError(response.error)) {
      solverRan = true;
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
          solverParsed = parsed.books.length;
        }
      }
    }
    if (solverRan) {
      AppLog.report(
        'category solver cat=$categoryId search=$inSearch parsed=${solverParsed ?? 'none'}',
        tag: 'category-search',
      );
    }
    // Temporary diagnostic (category search, 2026-11-12): the in-category
    // search returns 0 books even for a book listed in the browse. Log
    // what the fetch actually returned. Release-safe: status, page title
    // and counts only; no query, URL or cookie. Remove with the plugin
    // field.
    final categoryDebug = ZLibraryApiBase.lastCategoryFetchDebug;
    if (categoryDebug != null) {
      AppLog.report(
        'category fetch cat=$categoryId search=$inSearch $categoryDebug',
        tag: 'category-search',
      );
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

// ── Book Details ────────────────────────────────────────────────────

/// autoDispose：详情页关掉后无人 watch 即释放缓存。此前常驻内存，
/// 长会话逐本累积（每本详情是全量 [Book]）；相似书链路中每一页
/// 详情始终 watch 自己的 identifier，不会产生重复请求。
///
/// 返回书本体（eapi 详情 + 详情页 HTML 合并进来的 卷/ISBN/IPFS/评分
/// 字段），来自同一次 HTML 抓取（[ZLibraryApi.fetchBookDetailExtras]）。
final bookDetailsProvider =
    FutureProvider.autoDispose.family<Book, BookIdentifier>(
  (ref, identifier) async {
  final api = ref.watch(zlibraryApiProvider);
  final response = await api.getBookInfo(
    identifier.bookId,
    identifier.hashId,
    title: identifier.title,
  );
  if (!response.success) {
    throw StateError(response.error ?? 'Failed to load book details');
  }
  final book = response.data;
  if (book == null) {
    throw StateError('Book details response did not contain a book');
  }
  // Best-effort detail-page extras (volume / ISBN / IPFS / rating):
  // the eapi book does not carry them.
  // The HTML fetch runs AFTER the eapi detail loaded, so a slow or
  // walled page only delays the extra rows — the screen keeps showing
  // the eapi book meanwhile. The page sits behind the DiamWall: when
  // Dio answers the browser-check challenge, the repository
  // escalates to the WebView solver (same escalation as the
  // booklists / full-text / category HTML routes). Any failure
  // returns the eapi book unchanged.
  final href = identifier.href ?? book.href;
  if (href == null || href.isEmpty) {
    return book;
  }
  try {
    final user = ref.read(authProvider).user;
    final pageRepo = BookDetailPageRepository(api);
    final result = await pageRepo.fetch(
      href: href,
      userId: user?.id,
      userKey: user?.remixUserkey,
    );
    if (!result.success || result.data == null) {
      logIgnored(
        'book_details_metadata',
        StateError(result.error ?? 'book detail page failed'),
      );
      return book;
    }
    final metadata = result.data!.metadata;
    return book.copyWith(
      href: href,
      volume: metadata.volume,
      isbn10: metadata.isbn10,
      isbn13: metadata.isbn13,
      ipfsCid: metadata.ipfsCid,
      ipfsCidBlake2b: metadata.ipfsCidBlake2b,
      ratingInterest: metadata.ratingInterest,
      ratingQuality: metadata.ratingQuality,
    );
  } catch (error) {
    logIgnored('book_details_metadata', error);
    return book;
  }
  },
);

// ── External Search (Anna's Archive + LibGen) ────────────────────────
//
// Mirrors SearchNotifier's shape, but over a swappable external provider
// (Anna's Archive or LibGen, chosen by the search screen). Neither has
// total_pages in its HTML search results, so pagination runs until an
// empty page comes back (hasMore = the last page returned books).

class ExternalSearchState {
  final List<DisplayBook> books;
  final int currentPage;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasSearched;
  final bool hasMore;
  final String? error;

  const ExternalSearchState({
    this.books = const [],
    this.currentPage = 0,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasSearched = false,
    this.hasMore = true,
    this.error,
  });

  ExternalSearchState copyWith({
    List<DisplayBook>? books,
    int? currentPage,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasSearched,
    bool? hasMore,
    String? error,
  }) {
    return ExternalSearchState(
      books: books ?? this.books,
      currentPage: currentPage ?? this.currentPage,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasSearched: hasSearched ?? this.hasSearched,
      hasMore: hasMore ?? this.hasMore,
      error: error,
    );
  }
}

class ExternalSearchNotifier extends Notifier<ExternalSearchState> {
  // Getters / mutable fields, not `late final`: see SearchNotifier above.
  AnnasArchieve get _annasApi => ref.read(annasArchieveProvider);
  late SearchProvider _provider;
  late BookSource _source;
  String? _lastQuery;
  int _requestId = 0;

  @override
  ExternalSearchState build() {
    _provider = AnnasArchiveProvider(api: _annasApi);
    _source = BookSource.annasArchive;
    return const ExternalSearchState();
  }

  SearchProvider _providerFor(BookSource source) => source == BookSource.libgen
      ? LibgenProvider()
      : AnnasArchiveProvider(api: _annasApi);

  /// Maps a provider's BookData with the converter matching the source
  /// that produced it (Anna and LibGen both return BookData).
  DisplayBook _toDisplay(BookData book) => _source == BookSource.libgen
      ? book.toLibgenDisplayBook()
      : book.toAnnaDisplayBook();

  Future<void> search(String query, BookSource source) async {
    final requestId = ++_requestId;
    _lastQuery = query;
    _source = source;
    _provider = _providerFor(source);
    state = const ExternalSearchState(isLoading: true, hasSearched: true);

    try {
      final books = await _provider.search(SearchQuery(text: query, page: 1));
      if (requestId != _requestId) return;
      state = ExternalSearchState(
        books: books.map<DisplayBook>(_toDisplay).toList(),
        currentPage: 1,
        hasSearched: true,
        hasMore: books.isNotEmpty,
      );
    } catch (e) {
      if (requestId != _requestId) return;
      state = ExternalSearchState(
        hasSearched: true,
        error: _errorMessage(e),
      );
    }
  }

  Future<void> loadMore() async {
    if (_lastQuery == null ||
        state.isLoadingMore ||
        !state.hasMore) {
      return;
    }

    final nextPage = state.currentPage + 1;
    final requestId = _requestId;
    state = state.copyWith(isLoadingMore: true);

    try {
      final books = await _provider.search(
        SearchQuery(text: _lastQuery!, page: nextPage),
      );
      if (requestId != _requestId) return;
      state = state.copyWith(
        books: [
          ...state.books,
          ...books.map<DisplayBook>(_toDisplay),
        ],
        currentPage: nextPage,
        isLoadingMore: false,
        hasMore: books.isNotEmpty,
      );
    } catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(
        isLoadingMore: false,
        error: _errorMessage(e),
      );
    }
  }

  void reset() {
    _requestId++;
    _lastQuery = null;
    state = const ExternalSearchState();
  }

  /// NetworkError carries a human-readable userMessage (its toString is
  /// just `NetworkError.<type>`); surface that, fall back to toString.
  static String _errorMessage(Object e) {
    if (e is NetworkError) return e.userMessage;
    return e.toString();
  }
}

final externalSearchProvider =
    NotifierProvider<ExternalSearchNotifier, ExternalSearchState>(
      ExternalSearchNotifier.new,
    );

/// Shared [AnnasArchieve] instance: its Dio (and connection pool) is
/// reused across detail and search requests instead of being rebuilt
/// per call. The service holds no per-request mutable state (its headers
/// map is only read), so sharing one instance is safe.
final annasArchieveProvider =
    Provider<AnnasArchieve>((ref) => AnnasArchieve());

// ── Anna's Archive Book Details ──────────────────────────────────────
//
// [link] is the BookData.link from a search result (relative "/md5/…"
// URL). AnnasArchieve.bookInfo throws on failure (Cloudflare block, no
// mirror, parse failure), so the provider surfaces the error as-is.
/// autoDispose：详情页关掉后无人 watch 即释放缓存；每条 link 各占一
/// 个缓存项，重度浏览否则无界增长。
final annasBookDetailsProvider =
    FutureProvider.autoDispose.family<BookInfoData, String>((ref, link) async {
      final archive = ref.watch(annasArchieveProvider);
      return archive.bookInfo(url: link);
    });

/// Shared LibGen service instance. Creating one per detail request built
/// a fresh Dio (and a fresh keep-alive HttpClient pool) every time the
/// user opened a LibGen book — the same leak pattern the search side
/// already fixed with [annasArchieveProvider].
final libgenServiceProvider =
    Provider<LibgenService>((ref) => LibgenService());

// ── LibGen Book Details ──────────────────────────────────────────────
//
// [link] is the BookData.link from a search result (an absolute
// "ads.php?md5=…" URL). LibgenService.bookInfo returns null on failure
// (no mirror, non-200, parse failure), so the provider turns that into
// a StateError for the detail page's error UI.
/// autoDispose：与 [annasBookDetailsProvider] 同理，详情页关掉即释放。
final libgenBookDetailsProvider =
    FutureProvider.autoDispose.family<BookInfoData, String>((ref, link) async {
      final info = await ref.watch(libgenServiceProvider).bookInfo(link);
      if (info == null) throw StateError('Failed to load book details');
      return info;
    });

class BookIdentifier {
  final String bookId;
  final String hashId;

  /// Book title, used only to resolve the real eapi hash when the
  /// stored hash is a webpage short hash (see `getBookInfo`).
  final String? title;

  /// The book's webpage path (`/book/{hash}/{slug}.html`) when the
  /// list response that produced this book carried it. Used only to
  /// fetch the detail-page metadata (volume / ISBN / IPFS) that the
  /// eapi does not carry; null skips that fetch silently.
  final String? href;

  BookIdentifier(this.bookId, this.hashId, {this.title, this.href});

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BookIdentifier &&
        other.bookId == bookId &&
        other.hashId == hashId &&
        other.title == title &&
        other.href == href;
  }

  @override
  int get hashCode =>
      bookId.hashCode ^ hashId.hashCode ^ title.hashCode ^ href.hashCode;
}

// ── Book Lists ──────────────────────────────────────────────────────

final mostPopularBooksProvider = FutureProvider<List<Book>>((ref) async {
  final api = ref.watch(zlibraryApiProvider);
  final response = await api.getMostPopular();
  if (!response.success) {
    // Surface the failure as AsyncError so the UI shows its error/retry
    // branch — an API failure and a genuinely empty list must not look
    // identical (and only the former is retryable).
    throw StateError(response.error ?? 'Failed to load popular books');
  }
  return response.data ?? [];
});

final recommendedBooksProvider = FutureProvider<List<Book>>((ref) async {
  final api = ref.watch(zlibraryApiProvider);
  final response = await api.getUserRecommended();
  if (!response.success) {
    throw StateError(response.error ?? 'Failed to load recommendations');
  }
  // Diagnostic for issue #3 (temporary): log which source the home
  // recommendations actually came from. The popular fallback is silent,
  // so without this the home list can look "fixed" with no visible
  // cause. Release-safe: fixed reason literals plus a count only.
  final source = response.meta?['recommendedSource']?.toString();
  if (source != null) {
    AppLog.report(
      'home recommended source=$source books=${response.data?.length ?? 0}',
      tag: 'recommended',
    );
  }
  return response.data ?? [];
});

/// 首页推荐：z站推荐，转为 DisplayBook 列表。
final homeRecommendedProvider = Provider<AsyncValue<List<DisplayBook>>>((ref) {
  final zlibAsync = ref.watch(recommendedBooksProvider);
  // whenData keeps loading/error states as-is: the home screen keeps its
  // error/retry entry and keeps showing the previous data while a
  // revalidation after an account switch is in flight.
  return zlibAsync
      .whenData((books) => books.map((b) => b.toDisplay()).toList());
});

final recentBooksProvider = FutureProvider<List<Book>>((ref) async {
  final api = ref.watch(zlibraryApiProvider);
  final response = await api.getRecently();
  if (!response.success) {
    throw StateError(response.error ?? 'Failed to load recent books');
  }
  return response.data ?? [];
});

// ── Saved Books ─────────────────────────────────────────────────────

class SavedBooksNotifier extends Notifier<AsyncValue<List<Book>>> {
  // Getters, not `late final` fields: ref.invalidate (account switch, line
  // change, logout) re-runs build() on the SAME notifier instance, and a
  // second assignment to a late final throws LateInitializationError, which
  // left the provider in an error state and blanked the library screen.
  ZLibraryApi get _api => ref.read(zlibraryApiProvider);
  StorageService get _storage => ref.read(storageServiceProvider);

  @override
  AsyncValue<List<Book>> build() {
    loadSavedBooks();
    return const AsyncValue.loading();
  }

  /// 全量拉取收藏列表。[silent] 为 true 时是后台静默 revalidate：不
  /// 置 loading 态，失败时保留已有数据（只在尚无数据时才报 error），
  /// 收藏/取消后的后台对账就用它，列表不闪一下 loading。
  Future<void> loadSavedBooks({bool silent = false}) async {
    // build() 直接调这里，而首次 build 时 state 还不存在：读 `state`
    // 会抛 StateError（'Tried to read the state of an uninitialized
    // provider'），抛在 try 之前、第一个 await 之前，整个拉取直接
    // 夭折、provider 永远卡在 loading——冷启动图书馆无限转圈就是
    // 这么来的。`stateOrNull` 在未初始化时返回 null 而不抛，正是
    // Riverpod 给 build 期读 state 的写法；初始化之后和 `state` 等价。
    final hadData = stateOrNull?.valueOrNull != null;
    if (!silent) state = const AsyncValue.loading();

    try {
      const pageSize = 100;
      final books = <Book>[];
      final seen = <int>{};
      for (var page = 1; page <= 100; page++) {
        final response = await _api.getUserSaved(page: page, limit: pageSize);
        if (!response.success) {
          throw StateError(response.error ?? 'Could not load saved books');
        }
        final batch = response.data ?? <Book>[];
        final before = seen.length;
        for (final book in batch) {
          if (seen.add(book.id)) books.add(book);
        }
        final totalPages = int.tryParse(
          response.meta?['total_pages']?.toString() ?? '',
        );
        if ((totalPages != null && page >= totalPages) ||
            batch.length < pageSize ||
            seen.length == before) {
          break;
        }
      }
      state = AsyncValue.data(books);
    } catch (e, stack) {
      // 静默对账失败：已有列表是乐观更新后的正确内容，别用 error 覆盖它。
      if (silent && hadData) return;
      state = AsyncValue.error(e, stack);
    }
  }

  /// 后台静默对账：与服务端对一遍，不动 loading、不覆盖已有列表。
  Future<void> _revalidateSilently() => loadSavedBooks(silent: true);

  /// 本地乐观更新：当前列表已有数据时才改 state；尚无数据（首屏还
  /// 在加载）时返回 false，调用方改走全量 [loadSavedBooks]。
  bool _optimisticAdd(Book book) {
    final current = state.valueOrNull;
    if (current == null) return false;
    if (current.any((b) => b.id == book.id)) return true;
    // 服务端列表是新收藏在前，乐观插入放队首，后台对账再纠正顺序。
    state = AsyncValue.data([book, ...current]);
    return true;
  }

  bool _optimisticRemove(String bookId) {
    final current = state.valueOrNull;
    if (current == null) return false;
    if (!current.any((b) => b.id.toString() == bookId)) return true;
    state = AsyncValue.data(
      current.where((b) => b.id.toString() != bookId).toList(),
    );
    return true;
  }

  /// 收藏一本书。[book] 是详情页已有的完整 [Book]（经
  /// `DisplayBook.asZLibBook` 取到）：有它才能本地乐观插入；拿不到
  /// 时退回全量拉取。成功后立即返回，后台静默对账。
  Future<bool> saveBook(String bookId, {Book? book}) async {
    try {
      final response = await _api.saveBook(bookId);
      if (!response.success) return false;
      await _storage.addFavorite(bookId);
      if (book != null && _optimisticAdd(book)) {
        unawaited(_revalidateSilently());
      } else {
        await loadSavedBooks();
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 取消收藏一本书。[reload] 为 false 时不刷新列表（批量场景由调用方统一刷新）。
  Future<bool> unsaveBook(String bookId, {bool reload = true}) async {
    try {
      final response = await _api.unsaveUserBook(bookId);
      if (!response.success) return false;
      await _storage.removeFavorite(bookId);
      if (_optimisticRemove(bookId)) {
        if (reload) unawaited(_revalidateSilently());
      } else {
        if (reload) await loadSavedBooks();
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 批量取消收藏：逐本处理（每本都已乐观移除），全部完成后只静默
  /// 对账一次，不闪 loading。
  /// 返回成功取消的数量。
  Future<int> unsaveBooks(Iterable<String> bookIds) async {
    var removed = 0;
    for (final id in bookIds) {
      if (await unsaveBook(id, reload: false)) removed++;
    }
    await loadSavedBooks(silent: true);
    return removed;
  }
}

final savedBooksProvider =
    NotifierProvider<SavedBooksNotifier, AsyncValue<List<Book>>>(
      SavedBooksNotifier.new,
    );

// ── Downloaded Books ────────────────────────────────────────────────

/// 云端下载历史（账号维度的逐次下载记录，包含其他设备 / 网页端产生
/// 的下载）。
///
/// 数据源是网站的「下载历史」页 `/users/downloads`（服务端渲染 HTML，
/// 每次下载一行、50 行/页、?page=N 翻页）——这是全账号的下载日志。
/// eapi 的 `/eapi/user/book/downloaded` 不是这份数据：其他设备 /
/// 网页端的记录不在里面（2026-11-12 用户报告），只拿它来补元数据
/// （作者/封面/格式/大小），dstats 行本身只有 书id+标题+链接+时间。
///
/// 此前实现只读 eapi 列表（全量翻页），但 eapi 里根本没有其他设备 /
/// 网页端的记录——那些书永远看不到。现在与 [SavedBooksNotifier]
/// 同构：全量翻页 + 可静默对账，页面打开 / 下拉时都能拿到最新列表。
class DownloadedBooksNotifier extends Notifier<AsyncValue<List<Book>>> {
  // Getter, not a `late final` field: ref.invalidate (account switch,
  // line change, logout) re-runs build() on the SAME notifier instance,
  // and a second assignment to a late final throws LateInitializationError
  // — see SavedBooksNotifier above.
  ZLibraryApi get _api => ref.read(zlibraryApiProvider);

  /// 单调递增的拉取代号：每次拉取取下一个，只有最新一代能写 state。
  /// 打开页面、下拉刷新、账号切换可能让多次拉取重叠，慢的那次不
  /// 能用自己的旧页覆盖新一代已上屏的列表。
  int _generation = 0;

  /// 静默对账是否正在跑：build() 从缓存上屏后立刻起一个静默刷新，
  /// 历史页 initState 的 microtask 随后又会调一次——两次都是静默
  /// 对账，后一次只会重复拉第 1 页（代际守卫本就会丢弃旧的那次），
  /// 所以直接省掉。非静默调用不受影响，照常接管。
  bool _silentRefreshInFlight = false;

  @override
  AsyncValue<List<Book>> build() {
    final cached = _readCachedHistory();
    if (cached.isNotEmpty) {
      // Cache-first: paint the last known list immediately (first
      // paint ~0 s from cache), then refresh silently in the
      // background — the silent path never shrinks the visible list
      // and never replaces it with an error, so the cache stays up
      // until the fresh list catches up.
      unawaited(loadDownloadedBooks(silent: true));
      return AsyncValue.data(cached);
    }
    loadDownloadedBooks();
    return const AsyncValue.loading();
  }

  /// The cached server history for the signed-in account, in display
  /// order, or empty when signed out / nothing cached. Read
  /// synchronously so build() can paint it without awaiting.
  List<Book> _readCachedHistory() {
    final userId = ref.read(authProvider).user?.id;
    if (userId == null || userId.isEmpty) return const <Book>[];
    return ref
        .read(storageServiceProvider)
        .getServerDownloadHistorySyncForAccount(userId);
  }

  /// 全量拉取云端下载历史。dstats 是权威列表；eapi 列表只用来补
  /// 元数据，它失败不影响历史本身。服务端按下载时间倒序（最新在
  /// 前），按序拼接即保持该顺序，UI 的"按日期"排序仍等于服务端顺
  /// 序。[silent] 为 true 时是后台静默对账：不置 loading 态，失败时
  /// 保留已有数据（只在尚无数据时才报 error）——页面打开 / 下拉刷
  /// 新用它，列表不闪一下 loading。
  ///
  /// 渐进上屏：以前是等全部 dstats 页（最多 30 页）与全部 eapi 元
  /// 数据页都拉完才一次性 setState，慢链路上首屏要等几十秒。现在
  /// 每拉到一页 dstats 就上屏一次（最新 50 条先出来），eapi 元数
  /// 据在后台并行跑、到了再叠加补上——列表最终内容与以前完全一致，
  /// 只是出现得早。静默对账时已有列表保持可见，绝不先缩成半截再
  /// 长回来（paint 的缩短守卫）；最终那次 setState 不受守卫限制，
  /// 服务端删掉的记录也能正常消失。
  ///
  /// 代际守卫：每次调用取一个新代号，只有最新一代能写 state——
  /// 打开页面、下拉刷新、账号切换可能让多次拉取重叠，慢的那次不
  /// 能用自己的旧页覆盖新一代已上屏的列表。
  Future<void> loadDownloadedBooks({bool silent = false}) async {
    // 静默对账已在跑时不再重开一次（见 _silentRefreshInFlight）。
    if (silent && _silentRefreshInFlight) return;
    if (silent) _silentRefreshInFlight = true;
    // build() 直接调这里，而首次 build 时 state 还不存在：读 `state`
    // 会抛 StateError（见 SavedBooksNotifier 上的注释），`stateOrNull`
    // 在未初始化时返回 null 而不抛，正是 Riverpod 给 build 期读 state
    // 的写法。
    final hadData = stateOrNull?.valueOrNull != null;
    final generation = ++_generation;
    bool isCurrent() => generation == _generation;
    if (!silent) state = const AsyncValue.loading();
    // Temporary diagnostic (download history speed, 2026-11-12):
    // time the load end to end and per page, so the next log shows
    // whether the first page, the solver, or the page-by-page tail
    // is the slow part. Release-safe: timings and counts only; no
    // query, URL or cookie.
    final stopwatch = Stopwatch()..start();
    var pagesFetched = 0;
    var firstPaintLogged = false;

    final repository = DownloadStatsRepository(_api);
    final records = <Book>[];
    final seen = <String>{};
    var meta = const <int, Book>{};

    /// 当前累积记录叠加已到的元数据：只补空字段，dstats 自己的字段
    /// 不动。同一本书下载多次是多条独立记录，各自叠加。
    List<Book> overlay() => [
          for (final record in records)
            meta[record.id] == null
                ? record
                : record.copyWith(
                    author: meta[record.id]!.author,
                    cover: meta[record.id]!.cover,
                    extension: meta[record.id]!.extension,
                    filesize: meta[record.id]!.filesize,
                    filesizeString: meta[record.id]!.filesizeString,
                  ),
        ];

    /// 上屏一次累积列表。两条守卫：空累积不上屏（元数据先到时不能
    /// 把 loading 闪成空历史）；绝不把可见列表换短（静默对账时旧
    /// 列表先顶着，新列表没长到旧长度前不替换）。
    void paint() {
      if (!isCurrent() || records.isEmpty) return;
      final next = overlay();
      final current = stateOrNull?.valueOrNull;
      if (current != null && next.length < current.length) return;
      state = AsyncValue.data(next);
    }

    // eapi 元数据与 dstats 翻页并行跑；它只补作者/封面/格式/大小，
    // 到了就重叠一次，不再卡首屏。失败只损失这些字段（以前也一样
    // 容忍，只是以前要等它失败/成功才上屏）。
    unawaited(
      _fetchDownloadedMetadata().then<void>((m) {
        if (!isCurrent()) return;
        meta = m;
        AppLog.report(
          'dhistory meta ms=${stopwatch.elapsedMilliseconds} books=${m.length}',
          tag: 'download-history',
        );
        paint();
      }, onError: (Object e) {
        logIgnored('downloaded_meta', e);
      }),
    );

    try {
      const maxPages = 30;
      for (var page = 1; page <= maxPages; page++) {
        pagesFetched = page;
        final batch = await _fetchStatsPage(repository, page);
        if (!isCurrent()) return;
        final before = seen.length;
        for (final book in batch) {
          // 键含时间戳：同一本书下载多次是合法的多条记录，只有"整页
          // 逐条都和之前完全相同"才算没有新增。
          if (seen.add(
            '${book.id}|${book.downloadedAt?.toIso8601String()}|${book.title}',
          )) {
            records.add(book);
          }
        }
        // 终止：空页，或整页都是已见过的记录（服务端忽略 page 参数时
        // 每页回同一批，靠这个不空转）。
        final done = batch.isEmpty || seen.length == before;
        paint();
        if (!firstPaintLogged && records.isNotEmpty) {
          firstPaintLogged = true;
          AppLog.report(
            'dhistory first-paint ms=${stopwatch.elapsedMilliseconds} books=${records.length}',
            tag: 'download-history',
          );
        }
        if (done) break;
      }
      if (!isCurrent()) return;
      AppLog.report(
        'dhistory done ms=${stopwatch.elapsedMilliseconds} pages=$pagesFetched books=${records.length}',
        tag: 'download-history',
      );
      // 最终上屏：不受 paint 的缩短守卫限制，服务端已删的记录照
      // 常消失；元数据还在路上时它到了还会再叠加一次。
      final finalList = overlay();
      state = AsyncValue.data(finalList);
      // 缓存最后的上屏列表：下次打开先从缓存秒出，再静默刷新。
      // 只存非空的完整列表——空结果（失败/中途返回）绝不覆盖好缓存。
      if (finalList.isNotEmpty) {
        unawaited(
          ref
              .read(storageServiceProvider)
              .saveServerDownloadHistory(finalList),
        );
      }
    } catch (e, stack) {
      // 静默对账失败：已有列表是最后已知的好数据，别用 error 覆盖它。
      // build() 刚把缓存上屏时 state 尚未初始化，调用时算的 hadData
      // 是 false——这里按报错时的 state 再判一次，缓存列表同样受保护。
      if (silent && (hadData || stateOrNull?.valueOrNull != null)) return;
      if (!isCurrent()) return;
      AppLog.report(
        'dhistory error ms=${stopwatch.elapsedMilliseconds} type=${e.runtimeType}',
        tag: 'download-history',
      );
      state = AsyncValue.error(e, stack);
    } finally {
      if (silent) _silentRefreshInFlight = false;
    }
  }

  /// 一页 `/users/downloads`（50 行，最新在前）。
  ///
  /// 镜像会用浏览器验证墙拦页面路由（HTTP 503 browser check page，
  /// eapi 端点不拦）：撞墙的那一页改走 WebView challenge solver 过墙
  /// 重取；过墙后 wall cookies 回灌 Dio，后续页恢复快路径直连。solver
  /// 也失败时抛出原始墙错误（可重试），绝不把墙页解析成空历史。
  Future<List<Book>> _fetchStatsPage(
    DownloadStatsRepository repository,
    int page,
  ) async {
    // Temporary diagnostic (download history speed, 2026-11-12):
    // per-page fetch time and path. Release-safe: timings and
    // counts only.
    final pageStopwatch = Stopwatch()..start();
    final response = await repository.fetchPage(page: page);
    if (response.success) {
      AppLog.report(
        'dhistory page=$page ms=${pageStopwatch.elapsedMilliseconds} via=direct books=${response.data?.length ?? 0}',
        tag: 'download-history',
      );
      return response.data ?? const <Book>[];
    }
    if (repository.isChallengeError(response.error)) {
      return _fetchStatsPageViaSolver(
        repository,
        page,
        originalError: response.error ?? 'download history failed',
      );
    }
    throw StateError(
      response.error ?? 'Could not load download history',
    );
  }

  /// 一页 dstats 的 solver 回退：装会话 → WebView 过墙取渲染后的
  /// HTML → wall cookies 回灌 Dio → 解析。HTML 不是 dstats 页（落在
  /// 登录页等）或过墙失败时抛原始墙错误——wrong-page 守卫保证绝不满
  /// 足于一个"看似成功"的错误页。解析失败时再走一次可见 solver：无
  /// 头抓到的可能是空 503 页，或标题里没有验证墙关键字、墙的 JS 还
  /// 没跑完的墙页；可见页让墙在看得见的 WebView 里跑完，两次都解
  /// 析失败才抛原始墙错误。
  Future<List<Book>> _fetchStatsPageViaSolver(
    DownloadStatsRepository repository,
    int page, {
    required String originalError,
  }) async {
    // Temporary diagnostic (download history speed, 2026-11-12): see
    // _fetchStatsPage.
    final pageStopwatch = Stopwatch()..start();
    var via = 'solver';
    final user = ref.read(authProvider).user;
    final url = repository.pageUrl(page: page);
    final html = await repository.fetchViaSolver(
      url,
      userId: user?.id,
      userKey: user?.remixUserkey,
    );
    if (html == null) throw StateError(originalError);
    var parsed = repository.parsePage(html);
    if (parsed == null) {
      // solver 回来了 HTML，但它根本不是下载历史页：无头 WebView 抓
      // 到的可能是一个空的 503 报错页，或者标题里没有验证墙关键字、
      // 墙的 JS 在慢网速下还没跑完的墙页。不要直接按这页报错——再走
      // 一次可见 solver，让墙在看得见的 WebView 里跑完，解析那份 HTML。
      via = 'visible-solver';
      final visibleHtml = await repository.fetchViaVisibleSolver(
        url,
        userId: user?.id,
        userKey: user?.remixUserkey,
      );
      if (visibleHtml == null) throw StateError(originalError);
      parsed = repository.parsePage(visibleHtml);
      if (parsed == null) throw StateError(originalError);
    }
    AppLog.report(
      'dhistory page=$page ms=${pageStopwatch.elapsedMilliseconds} via=$via books=${parsed.length}',
      tag: 'download-history',
    );
    return parsed;
  }

  /// eapi downloaded 列表全量翻页，作 id→Book 元数据表（作者/封面/
  /// 格式/大小）。失败抛给调用方容忍（见 [loadDownloadedBooks]）。
  Future<Map<int, Book>> _fetchDownloadedMetadata() async {
    const pageSize = 100;
    final byId = <int, Book>{};
    for (var page = 1; page <= 100; page++) {
      final response = await _api.getUserDownloaded(
        page: page,
        limit: pageSize,
      );
      if (!response.success) {
        throw StateError(
          response.error ?? 'Could not load download metadata',
        );
      }
      final batch = response.data ?? const <Book>[];
      final before = byId.length;
      for (final book in batch) {
        byId.putIfAbsent(book.id, () => book);
      }
      final totalPages = int.tryParse(
        response.meta?['total_pages']?.toString() ?? '',
      );
      // 终止条件故意不用 batch.length < pageSize：镜像可能把 limit
      // 压到比 100 小，那只说明本页比请求的短，不代表没有下一页。
      // "到达 total_pages"或"整页都是重复（没有新增）"才可靠——
      // 后者同时兜住了服务端忽略 page 参数的情况（每页回同一批）。
      if ((totalPages != null && page >= totalPages) ||
          byId.length == before) {
        break;
      }
    }
    return byId;
  }
}

final downloadedBooksProvider =
    NotifierProvider<DownloadedBooksNotifier, AsyncValue<List<Book>>>(
      DownloadedBooksNotifier.new,
    );

/// Resolved detail covers for cloud history rows, keyed by book id.
///
/// The downloaded endpoint's cover value never loads, so a row whose
/// listed cover fails falls back to the detail endpoint's cover — the
/// same cover the detail page shows once its fetch completes.
class HistoryCoverNotifier extends Notifier<Map<String, String>> {
  final Set<String> _attempted = <String>{};

  @override
  Map<String, String> build() => const <String, String>{};

  Future<void> resolveCover(Book book) async {
    final id = book.id.toString();
    if (book.id == 0 || _attempted.contains(id)) return;
    _attempted.add(id);
    try {
      final response = await ref.read(zlibraryApiProvider).getBookInfo(
            id,
            book.hash ?? '',
            title: book.title,
          );
      final cover = response.data?.cover;
      if (response.success && cover != null && cover.isNotEmpty) {
        state = {...state, id: cover};
      }
    } catch (error) {
      // No usable cover: keep the placeholder. _attempted prevents
      // retry loops when the row rebuilds.
      logIgnored('history_cover', error);
    }
  }
}

final historyCoverProvider =
    NotifierProvider<HistoryCoverNotifier, Map<String, String>>(
      HistoryCoverNotifier.new,
    );

// ── Favorites Check ─────────────────────────────────────────────────

/// autoDispose：每本书一个缓存项；详情页关掉即释放，切换账号时
/// [invalidateAccountScopedProviders] 本来就会整体失效它。
final isBookFavoritedProvider = FutureProvider.autoDispose.family<bool, String>((
  ref,
  bookId,
) async {
  final storage = ref.watch(storageServiceProvider);
  return await storage.isFavorite(bookId);
});
