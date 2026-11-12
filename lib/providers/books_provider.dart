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

// ── Book Details ────────────────────────────────────────────────────

/// 详情页附加信息（卷/ISBN/IPFS/评分）的新鲜窗口：卷/ISBN/IPFS 是
/// 版本常量，只有两个社区评分会变（兴趣分另有 eapi interestScore
/// 兜底）——7 天内的旧评分换取重复打开整段跳过几百 KB 的 HTML 下载
/// （TTL 惯例同 BooklistHtmlCache）。
const _bookDetailExtrasTtl = Duration(days: 7);

/// 缓存键：详情页的 PATH（每版本稳定）。手动剥掉 query/fragment，
/// 不走 Uri.parse——它会把这个未编码的中文路径百分号编码，同一个
/// href 的键就因写法不同而漂移（CI 2026-11-13：测试夹具的中文 slug
/// 被编码成 %E5%90%88…，缓存全 miss）。
String _detailExtrasKey(String href) {
  final query = href.indexOf('?');
  final fragment = href.indexOf('#');
  var end = href.length;
  if (query >= 0 && query < end) end = query;
  if (fragment >= 0 && fragment < end) end = fragment;
  return href.substring(0, end);
}

bool _extrasFresh(Map<String, dynamic> extras) {
  final fetchedAt = extras['fetchedAt'];
  if (fetchedAt is! int) return false;
  return DateTime.now().millisecondsSinceEpoch - fetchedAt <
      _bookDetailExtrasTtl.inMilliseconds;
}

/// [BookDetailMetadata] → 可持久化的 JSON（7 个字段；fetchedAt 由
/// storage 层盖章）。
Map<String, dynamic> _extrasJsonOf(BookDetailMetadata metadata) => {
      'volume': metadata.volume,
      'isbn10': metadata.isbn10,
      'isbn13': metadata.isbn13,
      'ipfsCid': metadata.ipfsCid,
      'ipfsCidBlake2b': metadata.ipfsCidBlake2b,
      'ratingInterest': metadata.ratingInterest,
      'ratingQuality': metadata.ratingQuality,
    };

/// 缓存 JSON → 合并进书本体。逐字段容错取值：缓存是手改/旧版本的
/// JSON 时最坏也只是丢字段，绝不让详情页报错。
String? _extrasString(Object? value) => value is String ? value : null;

Book _applyExtrasJson(Book book, Map<String, dynamic> extras) =>
    book.copyWith(
      volume: _extrasString(extras['volume']),
      isbn10: _extrasString(extras['isbn10']),
      isbn13: _extrasString(extras['isbn13']),
      ipfsCid: _extrasString(extras['ipfsCid']),
      ipfsCidBlake2b: _extrasString(extras['ipfsCidBlake2b']),
      ratingInterest: _extrasString(extras['ratingInterest']),
      ratingQuality: _extrasString(extras['ratingQuality']),
    );

/// autoDispose：详情页关掉后无人 watch 即释放缓存。此前常驻内存，
/// 长会话逐本累积（每本详情是全量 [Book]）；相似书链路中每一页
/// 详情始终 watch 自己的 identifier，不会产生重复请求。
///
/// 返回书本体（eapi 详情 + 详情页 HTML 合并进来的 卷/ISBN/IPFS/评分
/// 字段），来自同一次 HTML 抓取（[ZLibraryApi.fetchBookDetailExtras]）。
///
/// 加载顺序（2026-11-13 重排；此前 HTML 严格排在 eapi 之后、且每次
/// 打开都重新下载几百 KB 的详情页）：
///
/// 1. 路由参数自带 href（搜索/列表结果都带）且持久缓存新鲜 →
///    **整段跳过 HTML 下载**，eapi 小 JSON 一到即用缓存字段合并上
///    屏——重复打开（7 天内）内容体即时完整。
/// 2. 缓存未命中或过期 → href 已知时 **HTML 与 eapi 并行**发起，
///    总时延取 max 而非相加；两源都到再合并，新字段回写缓存。
/// 3. HTML 失败 → 回退用过期缓存字段（比没有强）；都没有才返回
///    纯 eapi 书。eapi 本身的失败照旧抛出（页面显示错误 + 重试）。
/// 4. 路由参数没有 href → eapi 之后用其 href 串行抓（旧行为）。
final bookDetailsProvider =
    FutureProvider.autoDispose.family<Book, BookIdentifier>(
  (ref, identifier) async {
  final api = ref.watch(zlibraryApiProvider);
  final storage = ref.watch(storageServiceProvider);

  /// 抓 HTML 附加信息，成功时回写缓存并返回字段 JSON；失败返回
  /// null（异常折进结果——并行启动的这条不能以未处理异常炸掉）。
  Future<Map<String, dynamic>?> fetchExtrasJson(String href) async {
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
        return null;
      }
      final json = _extrasJsonOf(result.data!.metadata);
      unawaited(storage.mergeBookDetailExtras(_detailExtrasKey(href), json));
      return json;
    } catch (error) {
      logIgnored('book_details_metadata', error);
      return null;
    }
  }

  // 路由参数的 href 先查缓存：新鲜 → 不发 HTML 请求；否则立即并行
  // 发出（与下面的 eapi 详情同时跑）。
  final routeHref = identifier.href;
  final routeKey = (routeHref == null || routeHref.isEmpty)
      ? null
      : _detailExtrasKey(routeHref);
  final routeExtras =
      routeKey == null ? null : storage.getBookDetailExtrasSync(routeKey);
  final routeFresh = routeExtras != null && _extrasFresh(routeExtras);
  final routeFetch = (routeKey != null && !routeFresh)
      ? fetchExtrasJson(routeHref!)
      : null;

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
  final href = routeHref ?? book.href;
  if (href == null || href.isEmpty) {
    return book;
  }
  final hrefKey = _detailExtrasKey(href);
  final cached = routeKey == hrefKey
      ? routeExtras
      : storage.getBookDetailExtrasSync(hrefKey);

  // 并行抓取在途（缓存未命中或过期）：等它——成功用新值，失败用过
  // 期缓存兜底，都没有就返回纯 eapi 书。
  if (routeFetch != null) {
    final fetched = await routeFetch;
    if (fetched != null) {
      return _applyExtrasJson(book.copyWith(href: href), fetched);
    }
    if (cached != null) {
      return _applyExtrasJson(book.copyWith(href: href), cached);
    }
    return book.copyWith(href: href);
  }
  // 新鲜缓存：整段跳过 HTML 下载，eapi 一到即完整。
  if (cached != null) {
    return _applyExtrasJson(book.copyWith(href: href), cached);
  }
  // 无缓存且路由没带 href（book.href 才有）：串行抓——旧行为。
  final fetched = await fetchExtrasJson(href);
  if (fetched != null) {
    return _applyExtrasJson(book.copyWith(href: href), fetched);
  }
  return book.copyWith(href: href);
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

/// 一页 dstats 的流水线结果。[error] 非 null 时 [books] 为空，异常在
/// 按序消费到该页时原样上抛（保留旧的失败语义）；被终点之后的
/// listEnded 丢弃的 speculative 页则带着 error 静默消失。
typedef _StatsPageResult = ({List<Book> books, bool viaSolver, Object? error});

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
/// 2026-11-13 起加载分三段：dstats 窗口化预取、元数据持久缓存先行
/// 播种、eapi 只补缺失（见 [loadDownloadedBooks] 的文档）。
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

  /// 上次完整拉取完成的时刻（本会话内）：[silentRefreshTtl] 之内的
  /// 静默刷新直接跳过——完整翻页是整条链路最贵的一段，而列表缓存 +
  /// 元数据缓存已经让重复打开显示完整内容；下拉刷新传 force: true
  /// 照常全量拉。build()（invalidate，账号/线路切换）时清零，新
  /// 账号的缓存内容不同，不继承旧账号的 TTL。
  DateTime? _lastFullLoadAt;
  static const Duration silentRefreshTtl = Duration(minutes: 3);

  @override
  AsyncValue<List<Book>> build() {
    final cached = _readCachedHistory();
    if (cached.isNotEmpty) {
      // Cache-first: paint the last known list immediately (first
      // paint ~0 s from cache), then refresh silently in the
      // background — the silent path never shrinks the visible list
      // and never replaces it with an error, so the cache stays up
      // until the fresh list catches up.
      _lastFullLoadAt = null;
      unawaited(loadDownloadedBooks(silent: true));
      return AsyncValue.data(cached);
    }
    _lastFullLoadAt = null;
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
  /// 保留已有数据（只在尚无数据时才报 error）——页面打开 / build()
  /// 的后台对账用它；下拉刷新传 [force] = true，绕过静默 TTL 强制
  /// 全量拉，但同样不闪 loading。
  ///
  /// 三段结构（2026-11-13 重排；此前 eapi 元数据要全部翻完才叠加、
  /// 且每次打开都全量重跑，慢镜像上封面要等几十秒）：
  ///
  /// 1. dstats 窗口化预取：按页序上屏不变，抓取并行——page 1 先行，
  ///    返回非空后按窗口（2→4 逐波递增）发后续页，消费一页补发一
  ///    页；撞 solver 的页之后暂停发新 speculative 页（WebView 升级
  ///    很贵，不堆投机请求），后续快页恢复。终点之后在途的页直接
  ///    丢弃（issue() 把异常折进结果，绝不会变成未处理错误）。
  /// 2. 元数据持久缓存先行：eapi 的作者/封面/格式/大小按 book id 存
  ///    Hive（书级数据与账号无关），第一页 dstats 上屏时就带着封面
  ///    出现——此前要等 eapi 全部翻完。
  /// 3. dstats 拉完后只补缺失：缓存没覆盖到的 id（新下载）才翻
  ///    eapi，每页到达即叠加；缺失集清空 / 整页无新增 / 到达
  ///    total_pages 即停。缓存全覆盖时 eapi 循环整段跳过（重复打开
  ///    0 请求）。失败只损失元数据，照旧容忍。
  ///
  /// 代际守卫：每次调用取一个新代号，只有最新一代能写 state——
  /// 打开页面、下拉刷新、账号切换可能让多次拉取重叠，慢的那次不
  /// 能用自己的旧页覆盖新一代已上屏的列表。
  Future<void> loadDownloadedBooks({
    bool silent = false,
    bool force = false,
  }) async {
    // 静默对账已在跑时不再重开一次（见 _silentRefreshInFlight）。
    if (silent && _silentRefreshInFlight) return;
    // 静默 TTL：本会话刚完整拉取过就不再翻页（下拉 force 不受限；
    // 列表为空时不跳，首次加载没有可跳的依据）。
    if (silent &&
        !force &&
        _lastFullLoadAt != null &&
        DateTime.now().difference(_lastFullLoadAt!) < silentRefreshTtl &&
        stateOrNull?.valueOrNull?.isNotEmpty == true) {
      return;
    }
    if (silent) _silentRefreshInFlight = true;
    // build() 直接调这里，而首次 build 时 state 还不存在：读 `state`
    // 会抛 StateError（见 SavedBooksNotifier 上的注释），`stateOrNull`
    // 在未初始化时返回 null 而不抛，正是 Riverpod 给 build 期读 state
    // 的写法。
    final hadData = stateOrNull?.valueOrNull != null;
    final generation = ++_generation;
    bool isCurrent() => generation == _generation;
    if (!silent) state = const AsyncValue.loading();
    final repository = DownloadStatsRepository(_api);
    final records = <Book>[];
    final seen = <String>{};
    // 元数据表：持久缓存先播种（第一页 dstats 上屏即带封面/作者），
    // eapi 只补缺失并逐页并入。
    final meta = <int, Book>{
      ...ref.read(storageServiceProvider).getDownloadedBookMetadataSync(),
    };

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

    try {
      // ── 1. dstats：窗口化预取流水线 ──
      // page 1 先行（它决定后面有没有东西值得预取）；之后按序消费，
      // 消费一页补发一页。issue() 把异常折进结果：被放弃的 speculative
      // 页永远不抛未处理异常，真正的失败在按序消费时原样上抛（墙错
      // 误等，失败语义与旧的串行循环一致）。
      const maxPages = 30;
      var window = 2;
      var nextToIssue = 2;
      var issueAllowed = true; // 撞 solver 的页之后暂停，直到又见快页
      var listEnded = false;
      final pending = <int, Future<_StatsPageResult>>{};

      void topUp() {
        while (!listEnded &&
            issueAllowed &&
            nextToIssue <= maxPages &&
            pending.length < window) {
          final page = nextToIssue++;
          pending[page] = _issueStatsPage(repository, page);
        }
      }

      var consume = 1;
      while (consume <= maxPages && !listEnded) {
        final result = consume == 1
            ? await _issueStatsPage(repository, consume)
            : await (pending.remove(consume) ??
                _issueStatsPage(repository, consume));
        if (!isCurrent()) return;
        if (result.error != null) throw result.error!;
        final batch = result.books;
        // 撞 solver 的页之后暂停发新 speculative 抓取；后续快页恢复。
        issueAllowed = !result.viaSolver;
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
        if (batch.isEmpty || seen.length == before) {
          listEnded = true;
          // 终点之后的 speculative 页直接丢弃。
          pending.clear();
        } else {
          window = window < 4 ? window + 1 : window;
          topUp();
        }
        paint();
        consume++;
      }
      if (!isCurrent()) return;

      // ── 2+3. eapi：只补缺失的元数据 ──
      // 持久缓存（播种）没覆盖到的 id（新下载）才翻页；每页到达即
      // 叠加一次。失败只损失元数据（与旧行为一致），不影响列表。
      final missing = <int>{
        for (final record in records)
          if (!meta.containsKey(record.id)) record.id,
      };
      if (missing.isNotEmpty) {
        try {
          await _fillMissingMetadata(
            missing: missing,
            meta: meta,
            onPage: () {
              if (isCurrent()) paint();
            },
          );
        } catch (e) {
          logIgnored('downloaded_meta', e);
        }
        if (!isCurrent()) return;
        // 新学到的元数据并回持久缓存（顺带把播种的原样写回，幂等）。
        unawaited(
          ref.read(storageServiceProvider).mergeDownloadedBookMetadata(meta),
        );
      }

      // 最终上屏：不受 paint 的缩短守卫限制，服务端已删的记录照
      // 常消失。
      final finalList = overlay();
      state = AsyncValue.data(finalList);
      _lastFullLoadAt = DateTime.now();
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
      state = AsyncValue.error(e, stack);
    } finally {
      if (silent) _silentRefreshInFlight = false;
    }
  }

  /// 一页 `/users/downloads`（50 行，最新在前），以及它走的路径：
  /// [viaSolver] 为 true 表示这页经过了 WebView solver（流水线用它
  /// 暂停发新 speculative 页）。
  ///
  /// 镜像会用浏览器验证墙拦页面路由（HTTP 503 browser check page，
  /// eapi 端点不拦）：撞墙的那一页改走 WebView challenge solver 过墙
  /// 重取；过墙后 wall cookies 回灌 Dio，后续页恢复快路径直连。solver
  /// 也失败时抛出原始墙错误（可重试），绝不把墙页解析成空历史。
  Future<({List<Book> books, bool viaSolver})> _fetchStatsPage(
    DownloadStatsRepository repository,
    int page,
  ) async {
    final response = await repository.fetchPage(page: page);
    if (response.success) {
      return (books: response.data ?? const <Book>[], viaSolver: false);
    }
    if (repository.isChallengeError(response.error)) {
      final books = await _fetchStatsPageViaSolver(
        repository,
        page,
        originalError: response.error ?? 'download history failed',
      );
      return (books: books, viaSolver: true);
    }
    throw StateError(
      response.error ?? 'Could not load download history',
    );
  }

  /// 流水线的单页抓取：把 [_fetchStatsPage] 的异常折进结果——被终点
  /// 之后的 listEnded 丢弃的 speculative 页绝不能以未处理异步异常的
  /// 形式炸掉 zone；真正的失败在按序消费到该页时原样上抛。
  Future<_StatsPageResult> _issueStatsPage(
    DownloadStatsRepository repository,
    int page,
  ) async {
    try {
      final result = await _fetchStatsPage(repository, page);
      return (books: result.books, viaSolver: result.viaSolver, error: null);
    } catch (e) {
      return (books: const <Book>[], viaSolver: false, error: e);
    }
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
      final visibleHtml = await repository.fetchViaVisibleSolver(
        url,
        userId: user?.id,
        userKey: user?.remixUserkey,
      );
      if (visibleHtml == null) throw StateError(originalError);
      parsed = repository.parsePage(visibleHtml);
      if (parsed == null) throw StateError(originalError);
    }
    return parsed;
  }

  /// eapi downloaded 列表翻页，补齐 [missing] 里还没有元数据的 id：
  /// 每页到达即并入 [meta] 并回调 [onPage]（渐进叠加），缺失集清空 /
  /// 整页没有任何新 id / 到达 total_pages 即停。失败抛给调用方容忍。
  Future<void> _fillMissingMetadata({
    required Set<int> missing,
    required Map<int, Book> meta,
    required void Function() onPage,
  }) async {
    const pageSize = 100;
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
      final before = meta.length;
      for (final book in batch) {
        missing.remove(book.id);
        meta[book.id] = book;
      }
      onPage();
      // 终止条件故意不用 batch.length < pageSize：镜像可能把 limit
      // 压到比 100 小，那只说明本页比请求的短，不代表没有下一页。
      // "缺失集清空"、"到达 total_pages"或"整页没有任何新 id（服务
      // 端忽略 page 参数时每页回同一批）"才可靠。注意中间那条必须
      // 是"任何新 id"而不是"找到缺失"：缺失的 id 可能是服务端已删
      // 的书、永远找不到，但它们之间的页还在带来别的元数据。
      if (missing.isEmpty) break;
      final totalPages = int.tryParse(
        response.meta?['total_pages']?.toString() ?? '',
      );
      if ((totalPages != null && page >= totalPages) ||
          meta.length == before) {
        break;
      }
    }
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

  /// 有界并发（4）+ FIFO：元数据落地前每个封面失败的行都会来要一次
  /// 详情请求，50 行的一页在慢镜像上瞬间能排进几十个请求；排队限流
  /// 让它们慢慢消化，详情请求本身不快也没关系（结果异步叠加回
  /// state）。_attempted 照旧防止行重建导致的重试循环。
  static const int _maxInFlight = 4;
  final List<Book> _queue = <Book>[];
  var _inFlight = 0;

  @override
  Map<String, String> build() => const <String, String>{};

  Future<void> resolveCover(Book book) async {
    final id = book.id.toString();
    if (book.id == 0 || _attempted.contains(id)) return;
    _attempted.add(id);
    _queue.add(book);
    _drain();
  }

  void _drain() {
    while (_inFlight < _maxInFlight && _queue.isNotEmpty) {
      final book = _queue.removeAt(0);
      _inFlight++;
      _resolve(book).whenComplete(() {
        _inFlight--;
        _drain();
      });
    }
  }

  Future<void> _resolve(Book book) async {
    final id = book.id.toString();
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
