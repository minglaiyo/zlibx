import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../constants/search_filters.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../models/display_book.dart';
import '../../providers/article_search_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/books_provider.dart';
import '../../providers/fulltext_search_provider.dart';
import '../../providers/search_filter_options_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/update_provider.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_metrics.dart';
import '../../utils/app_log.dart';
import '../../utils/app_snack.dart';
import '../../utils/isbn.dart';
import '../../widgets/update_dialog.dart';
import '../reader/reader_screen.dart';
import 'barcode_scanner_screen.dart';
import 'recent_searches_store.dart';
import 'search_filters.dart';
import 'search_scroll_handler.dart';
import 'widgets/search_body_view.dart';
import 'widgets/search_filter_dialog.dart';
import 'widgets/search_glass_header.dart';
import 'widgets/search_mode_selector.dart';

export 'search_screen_args.dart';

class SearchScreen extends ConsumerStatefulWidget {
  final BookSource? initialSource;

  /// Category to browse on open (empty query): set when the screen
  /// is opened from a book-detail category chip or the category
  /// picker. Null means a plain search screen.
  final int? initialCategoryId;
  final String? initialCategoryName;

  /// Query to pre-fill and run on open: set when the screen
  /// is opened from a book-detail author/publisher tap. Null means no
  /// preset query.
  final String? initialQuery;

  /// Field the [initialQuery] is scoped to (detail-page
  /// author/publisher tap). Null is an unscoped general search.
  final SearchField? initialField;

  const SearchScreen({
    super.key,
    this.initialSource,
    this.initialCategoryId,
    this.initialCategoryName,
    this.initialQuery,
    this.initialField,
  });

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

/// Orchestrator only: owns the query state (controller), the applied
/// filters ([SearchFilters]) and the recent-searches store, and wires
/// the presentation widgets (`widgets/search_glass_header.dart` 的
/// 头部、`widgets/search_body_view.dart` 的分支梯) together. 搜索只在
/// 用户按下搜索键时发起（[SearchBarField.onSubmitted]）；输入过程不发
/// 任何网络请求（曾经的实时 Google 搜索建议已于 2026-11-13 移除——
/// 按键即联网的行为与"按搜索键才搜"的预期冲突，慢链路上尤其打扰）。
///
/// 三个 ValueNotifier 把高频重建从整屏收窄到局部（审查 B2）：
///  * [_glassHeaderHeight]——头部布局期高度 → 结果区让位 padding；
///  * [_scrollHandler]——chips 列滚动折叠，折叠动画帧不再重挂整屏；
///  * [_isListView]——网格↔列表切换，只重建结果区。
/// 建议面板的逐字刷新由头部自己监听输入框（只重建头部一层）。
class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _searchController = TextEditingController();

  /// 搜索建议（D1）的焦点态：面板只在输入框聚焦、查询非空且与上次
  /// 提交的不同（正在编写新查询）时出现；提交后随结果出现而收起。
  final _searchFocus = FocusNode();

  // z站通用搜索结果的 DisplayBook 缓存。此前 build 里每次
  // `searchState.books.map((b) => b.toDisplay()).toList()`——每个
  // setState（输入建议、视图切换、滚动加载计数）都重映射整页结果；
  // provider 每次数据变更都换新列表实例（[...books, ...] 或全新
  // 列表），所以按实例身份缓存即可，结果变更必然重算。
  List<Book>? _displaySourceBooks;
  List<DisplayBook> _displayBooks = const [];

  List<DisplayBook> _resolveDisplayBooks(List<Book> books) {
    if (!identical(books, _displaySourceBooks)) {
      _displaySourceBooks = books;
      _displayBooks = books.map((b) => b.toDisplay()).toList();
    }
    return _displayBooks;
  }

  // ── 毛玻璃遮罩头部(2026-11-20,与首页同款)──
  // 搜索框 + 建议面板 + chips 头部悬浮,结果从底下穿过;头部高度由
  // 头部的 _MeasureSize 在布局期实时上报(折叠/建议面板/键盘都会变),
  // 结果区的让位 padding 用 ValueListenableBuilder 跟随。
  final ValueNotifier<double> _glassHeaderHeight = ValueNotifier(68);

  // ── Filters (edited on the filter page, applied on 使用) ──
  final SearchFilters _filters = SearchFilters();

  // ── z站 search mode: 通用 / 文章 / 全文检索. The full-text-only
  // extras (words/phrase match + exact flag) live in [SearchFilters];
  // their default is `words` / off (the site's working default,
  // device-proven 2026-11-11). The order default differs per mode
  // ('popular' for full-text, 'default' for general and article
  // search) — see _switchMode.
  SearchMode _mode = SearchMode.general;

  /// 网格↔列表切换：ValueNotifier，切换只重建结果区（审查 B2）。
  final ValueNotifier<bool> _isListView = ValueNotifier(false);

  bool _isQueryEmpty = true;

  /// Recent-search keywords (Hive-backed, de-duped, capped at 12).
  final _recentSearches = RecentSearchesStore();

  /// Scroll-driven header fold + load-more (see [SearchScrollHandler]).
  late final _scrollHandler = SearchScrollHandler(onLoadMore: _loadMore);

  String _lastSubmittedQuery = '';

  /// Field the current query is scoped to (detail-page author/
  /// publisher tap). Null = unscoped general search. Cleared on
  /// clear / source switch / mode switch, the same way the category
  /// scope is.
  SearchField? _field;

  late BookSource _source;

  @override
  void initState() {
    super.initState();
    _source = widget.initialSource ?? BookSource.zlibrary;
    _filters.categoryId = widget.initialCategoryId;
    _filters.categoryName = widget.initialCategoryName;
    _recentSearches.load();
    // Opened with a query (detail-page author/publisher tap): put
    // the query in the box before the listener is attached, so the
    // empty-state flag is set here rather than via a setState in
    // initState.
    final initialQuery = widget.initialQuery?.trim();
    if (initialQuery != null && initialQuery.isNotEmpty) {
      _searchController.text = initialQuery;
      _isQueryEmpty = false;
    }
    // Field scope from a detail-page author/publisher tap: survives
    // until the query is cleared, the source or the mode switches.
    _field = widget.initialField;
    _searchController.addListener(_onQueryChanged);
    // Opened with a category (detail-page chip): browse it
    // immediately — an empty query plus a category is a browse, not
    // an empty page.
    if (_filters.categoryId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _runSearch();
      });
    }
    // Opened with a query: run it right after the first frame — the
    // query is already in the box, so the results come up directly.
    if (initialQuery != null && initialQuery.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _performSearch();
      });
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_onQueryChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    _glassHeaderHeight.dispose();
    _scrollHandler.dispose();
    _isListView.dispose();
    super.dispose();
  }

  // ── Query state ──────────────────────────────────────────────

  void _onQueryChanged() {
    // 只跟踪空/非空（决定空态视图与建议/历史区）；搜索本身只在按
    // 下搜索键时发起——输入过程不发任何网络请求。建议面板的逐字刷
    // 新在 SearchGlassHeader 内自管（它自己监听输入框，只重建头部
    // 一层），这里不再整屏 setState（审查 v2 P2）。
    final isEmpty = _searchController.text.trim().isEmpty;
    if (isEmpty != _isQueryEmpty) {
      setState(() => _isQueryEmpty = isEmpty);
    }
  }

  // ── Recent searches ──────────────────────────────────────────

  Future<void> _saveRecentSearches(List<String> searches) async {
    setState(() => _recentSearches.searches = searches);
    // 无痕模式（隐私锁配套）：内存态保留（本次会话 UI 照常），不落盘。
    if (ref.read(incognitoModeProvider)) return;
    try {
      await _recentSearches.persist();
    } catch (error) {
      AppLog.report(
        'Failed to save recent searches: ${error.runtimeType}',
        tag: 'search_screen',
      );
      if (mounted) {
        showAppSnack(
          context,
          AppLocalizations.of(context)!.searchHistorySaveFailed,
        );
      }
    }
  }

  void _rememberSearch(String query) {
    unawaited(_saveRecentSearches(_recentSearches.remembered(query)));
  }

  void _searchAgain(String keyword) {
    _searchController.text = keyword;
    _searchController.selection = TextSelection.collapsed(
      offset: keyword.length,
    );
    FocusScope.of(context).unfocus();
    _performSearch();
  }

  void _removeRecentSearch(String keyword) {
    unawaited(_saveRecentSearches(_recentSearches.without(keyword)));
  }

  void _clearRecentSearches() {
    unawaited(_saveRecentSearches([]));
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _lastSubmittedQuery = '';
      _field = null;
    });
    ref.read(searchProvider.notifier).reset();
    ref.read(fulltextSearchProvider.notifier).reset();
    ref.read(articleSearchProvider.notifier).reset();
    ref.read(externalSearchProvider.notifier).reset();
    // A picked category survives clearing the query: empty query
    // plus a category is a browse, so go back to browsing it (the
    // old category screen's clear-search did the same) — but only
    // in the z站 general search, where a category means anything.
    if (_filters.categoryId != null &&
        _source == BookSource.zlibrary &&
        _mode == SearchMode.general) {
      _runSearch();
    }
  }

  /// 扫码搜书：打开全屏条码扫描页，扫到的 ISBN-13 直接作为查询词搜。
  /// An ISBN is an unscoped search: drop any author/publisher field
  /// scope from a previous tap-to-search before running it.
  Future<void> _openBarcodeScanner() async {
    final isbn = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const BarcodeScannerScreen()),
    );
    if (isbn == null || isbn.isEmpty || !mounted) return;
    setState(() {
      _searchController.text = isbn;
      _field = null;
    });
    _performSearch();
  }

  // ── Filter handling ──────────────────────────────────────────

  /// A filter change re-runs the current query immediately so the
  /// result set always reflects the visible filter chips. Re-runs
  /// only when there is something to run: a submitted query, or a
  /// picked category (empty query plus a category is a browse).
  void _applyFilterChange() {
    setState(() {});
    final query = _searchController.text.trim();
    final canRun = query.isEmpty
        ? _filters.categoryId != null
        : query == _lastSubmittedQuery;
    if (canRun) _performSearch();
  }

  void _resetLanguageFilter() {
    _filters.language = 'all';
    _applyFilterChange();
  }

  void _resetOrderFilter() {
    _filters.order = _mode == SearchMode.fulltext ? 'popular' : 'default';
    _applyFilterChange();
  }

  void _resetExtensionFilter() {
    _filters.extension = 'all';
    _applyFilterChange();
  }

  void _resetYearFromFilter() {
    _filters.yearFrom = null;
    _applyFilterChange();
  }

  void _resetYearToFilter() {
    _filters.yearTo = null;
    _applyFilterChange();
  }

  void _resetExactFilter() {
    if (_mode == SearchMode.fulltext) {
      _filters.fullTextExact = false;
    } else {
      _filters.generalExact = false;
    }
    _applyFilterChange();
  }

  /// Clear the category scope (and the content type, which only
  /// exists inside a category). With an empty query the stale
  /// category results are dropped too, so the empty-query view shows
  /// again; with a submitted query the search re-runs unscoped.
  void _resetCategoryFilter() {
    _filters.categoryId = null;
    _filters.categoryName = null;
    _filters.contentType = null;
    if (_searchController.text.trim().isEmpty) {
      ref.read(searchProvider.notifier).reset();
    }
    _applyFilterChange();
  }

  void _resetContentTypeFilter() {
    _filters.contentType = null;
    _applyFilterChange();
  }

  /// The filter button in the search bar: opens the filter dialog
  /// with the current locale's display names (same maps the chips
  /// mirror). Article mode passes empty language / extension maps —
  /// their rows hide (the request carries none of those filters).
  /// The dialog stages edits and only returns them when 使用 is
  /// tapped; closing discards.
  ///
  /// Plan item 6: the name maps come from the server-merged options
  /// when available; while loading (or when the fetch failed) the
  /// hardcoded tables are the UI.
  void _openFilterDialogForCurrentLocale() {
    final locale = Localizations.localeOf(context).languageCode;
    final filterOptions =
        ref.read(searchFilterOptionsProvider).valueOrNull ??
        SearchFilterOptions.local();
    // 文章模式（v2）与全文一样带语言/格式筛选：`/s/` 表单的筛选参数
    // 名已站点验证（languages[]/extensions[]），不再隐藏这两行。
    unawaited(
      _openFilterDialog(
        languageDisplayNamesFor(filterOptions.languages, locale),
        _mode == SearchMode.fulltext
            ? getFulltextOrderDisplayNames(locale)
            : getOrderDisplayNames(locale),
        extensionDisplayNamesFor(filterOptions.extensions, locale),
      ),
    );
  }

  Future<void> _openFilterDialog(
    Map<String, String> languageNames,
    Map<String, String> orderNames,
    Map<String, String> extensionNames,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showDialog<SearchFilterResult>(
      context: context,
      builder: (context) => SearchFilterDialog(
        mode: _mode,
        language: _filters.language,
        order: _filters.order,
        extension: _filters.extension,
        yearFrom: _filters.yearFrom,
        yearTo: _filters.yearTo,
        exact: _filters.exactFor(_mode),
        matchType: _filters.fullTextMatchType,
        contentType: _filters.contentType,
        categoryId: _filters.categoryId,
        categoryName: _filters.categoryName,
        languageNames: languageNames,
        orderNames: orderNames,
        extensionNames: extensionNames,
        contentTypeNames: {
          'book': l10n.contentTypeBook,
          'article': l10n.contentTypeArticle,
        },
        defaultOrder: _mode == SearchMode.fulltext ? 'popular' : 'default',
        showCategory:
            _source == BookSource.zlibrary && _mode == SearchMode.general,
      ),
    );
    if (result == null || !mounted) return;
    _filters.applyFrom(result, mode: _mode);
    _applyFilterChange();
  }

  // ── Search execution ─────────────────────────────────────────

  void _performSearch() {
    final query = _searchController.text.trim();
    // An empty query is a browse, not a no-op, when a category is
    // picked — but it is never remembered as a recent search, and it
    // only browses in the z站 general search (a category means
    // nothing on another source or mode).
    final canBrowseCategory =
        _filters.categoryId != null &&
        _source == BookSource.zlibrary &&
        _mode == SearchMode.general;
    if (query.isEmpty && !canBrowseCategory) return;
    setState(() {
      _lastSubmittedQuery = query;
    });
    if (_runSearch() && query.isNotEmpty) _rememberSearch(query);
  }

  bool _runSearch() {
    if (ref.read(updateProvider).isBlocked) {
      unawaited(showUpdateDialog(context));
      return false;
    }

    // A fresh search reloads the results from the top, so a
    // scroll-folded header comes back with them (and the
    // accumulated scroll direction starts over). ValueNotifier 写入
    // 即可——值相同不通知，头部自己收。
    _scrollHandler.reset();

    // Plan item 7: a whole query that is a bare ISBN (typed or pasted,
    // with or without separators) searches its canonical ISBN-13
    // digits; anything else goes out unchanged. The box keeps the
    // user's text — only the request is normalised.
    final query = normalizeIsbnQuery(_searchController.text.trim());
    // Plan item 6: the API values come from the server-merged options
    // when available; while loading (or when the fetch failed) the
    // hardcoded tables are the request.
    final filterOptions =
        ref.read(searchFilterOptionsProvider).valueOrNull ??
        SearchFilterOptions.local();
    final languageApiValues = filterOptions.languageApiValues;
    final extensionApiValues = filterOptions.extensions;
    if (_source != BookSource.zlibrary) {
      ref
          .read(externalSearchProvider.notifier)
          .search(query, _source, field: _field);
      return true;
    }

    if (_mode == SearchMode.fulltext) {
      ref
          .read(fulltextSearchProvider.notifier)
          .search(
            FullTextSearchParams(
              query: query,
              type: _filters.fullTextMatchType,
              exact: _filters.fullTextExact,
              yearFrom: _filters.yearFrom,
              yearTo: _filters.yearTo,
              languages: languageApiValues[_filters.language] != null
                  ? [languageApiValues[_filters.language]!]
                  : null,
              extensions: extensionApiValues[_filters.extension] != null
                  ? [extensionApiValues[_filters.extension]!]
                  : null,
              order: _filters.order,
            ),
          );
      return true;
    }

    if (_mode == SearchMode.article) {
      ref
          .read(articleSearchProvider.notifier)
          .search(
            ArticleSearchParams(
              query: query,
              order: searchOrders[_filters.order],
              exact: _filters.generalExact,
              yearFrom: _filters.yearFrom,
              yearTo: _filters.yearTo,
              languages: languageApiValues[_filters.language] != null
                  ? [languageApiValues[_filters.language]!]
                  : null,
              extensions: extensionApiValues[_filters.extension] != null
                  ? [extensionApiValues[_filters.extension]!]
                  : null,
            ),
          );
      return true;
    }

    // A picked category scopes the general search to the category
    // HTML routes (browse when the query is empty, in-category
    // search otherwise) with the same filters the old category
    // screen passed; without one it is the plain eapi search.
    if (_filters.categoryId != null) {
      ref
          .read(searchProvider.notifier)
          .search(
            SearchParams(
              query: query,
              yearFrom: _filters.yearFrom,
              yearTo: _filters.yearTo,
              languages: languageApiValues[_filters.language] != null
                  ? [languageApiValues[_filters.language]!]
                  : null,
              extensions: extensionApiValues[_filters.extension] != null
                  ? [extensionApiValues[_filters.extension]!]
                  : null,
              order: searchOrders[_filters.order],
              exact: _filters.generalExact,
              categoryId: _filters.categoryId,
              contentTypes: _filters.contentType == null
                  ? null
                  : [_filters.contentType!],
            ),
          );
      return true;
    }

    ref
        .read(searchProvider.notifier)
        .search(
          SearchParams(
            query: query,
            yearFrom: _filters.yearFrom,
            yearTo: _filters.yearTo,
            languages: languageApiValues[_filters.language] != null
                ? [languageApiValues[_filters.language]!]
                : null,
            extensions: extensionApiValues[_filters.extension] != null
                ? [extensionApiValues[_filters.extension]!]
                : null,
            order: searchOrders[_filters.order],
            exact: _filters.generalExact,
            // Field scope from a detail-page author/publisher tap:
            // the eapi search has no server-side field parameter, so
            // the provider filters the returned books client-side.
            field: _field,
          ),
        );
    return true;
  }

  void _switchSource(BookSource source) {
    if (source == _source) return;
    setState(() {
      _source = source;
      _lastSubmittedQuery = '';
      _field = null;
    });
    ref.read(searchProvider.notifier).reset();
    ref.read(fulltextSearchProvider.notifier).reset();
    ref.read(articleSearchProvider.notifier).reset();
    ref.read(externalSearchProvider.notifier).reset();
    if (_searchController.text.trim().isNotEmpty) {
      _performSearch();
    } else if (_filters.categoryId != null && source == BookSource.zlibrary) {
      // Back to z站 with a category picked: browse it again (the
      // reset above dropped the results).
      _runSearch();
    }
  }

  /// Switch between the z站 search modes (通用 / 文章 / 全文检索). The
  /// sort selection resets to the new mode's default ('popular' for
  /// full-text, 'default' for general and article) so a sort value
  /// from one mode can never leak into the other endpoint's request.
  /// The category scope clears with it — a category belongs to the
  /// general search, the way its sort default does.
  void _switchMode(SearchMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _filters.order = mode == SearchMode.fulltext ? 'popular' : 'default';
      _filters.categoryId = null;
      _filters.categoryName = null;
      _filters.contentType = null;
      _lastSubmittedQuery = '';
      _field = null;
    });
    ref.read(searchProvider.notifier).reset();
    ref.read(fulltextSearchProvider.notifier).reset();
    ref.read(articleSearchProvider.notifier).reset();
    if (_searchController.text.trim().isNotEmpty) _performSearch();
  }

  /// 结果列表滚到距底部 200px 内时加载下一页。四个源的分发此前在
  /// _onScroll 与重试按钮里各写了一份，收口到这里。
  void _loadMore() {
    if (_source != BookSource.zlibrary) {
      ref.read(externalSearchProvider.notifier).loadMore();
    } else if (_mode == SearchMode.fulltext) {
      ref.read(fulltextSearchProvider.notifier).loadMore();
    } else if (_mode == SearchMode.article) {
      ref.read(articleSearchProvider.notifier).loadMore();
    } else {
      ref.read(searchProvider.notifier).loadMore();
    }
  }

  void _openBook(DisplayBook book) {
    // A removed book from a category list keeps its download blocked
    // on the detail page (the category pages carry the per-card
    // unavailability; plain search results have none).
    final zBook = book.asZLibBook;
    final unavailableReason = zBook == null
        ? null
        : ref.read(searchProvider).unavailableReasons[zBook.id];
    AppRoutes.openBookDetailForDisplayBook(
      context,
      book,
      unavailableReason: unavailableReason,
    );
  }

  void _openFullTextHit(FullTextHit hit) {
    AppRoutes.openBookDetailForDisplayBook(
      context,
      hit.book.toDisplay(),
      unavailableReason: hit.unavailableReason,
    );
  }

  /// Opens one article's site detail page in the reader WebView —
  /// the same session-installed page the online reader uses. Articles
  /// have no eapi detail flow (those endpoints are book-only), so the
  /// site's own page (which carries the download button) is the v1
  /// interaction. The URL host is the API line's own domain — the
  /// same host the session was already issued for — so the session
  /// rides along whenever the user is signed in. Removed articles
  /// still open (site behaviour: the page stays reachable).
  void _openArticle(Article article) {
    final url = article.url;
    if (url == null || url.isEmpty) return;
    final user = ref.read(authProvider).user;
    AppRoutes.openReader(
      context,
      ReaderArgs(
        url: url,
        title: article.title,
        remixUserId: user?.id,
        remixUserKey: user?.remixUserkey,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).languageCode;
    // Plan item 6: the chips mirror the server-merged options when
    // available; while loading (or when the fetch failed) the
    // hardcoded tables are the UI.
    final filterOptions =
        ref.watch(searchFilterOptionsProvider).valueOrNull ??
        SearchFilterOptions.local();
    final languageNames = languageDisplayNamesFor(
      filterOptions.languages,
      locale,
    );
    final orderNames = _mode == SearchMode.fulltext
        ? getFulltextOrderDisplayNames(locale)
        : getOrderDisplayNames(locale);
    final extensionNames = extensionDisplayNamesFor(
      filterOptions.extensions,
      locale,
    );
    final isExternal = _source != BookSource.zlibrary;
    // 外观设置里的"书籍网格自适应列数"（默认关）。结果网格和它的加载
    // 骨架共用同一个值。
    final adaptiveGrid = ref.watch(adaptiveGridProvider);

    final view = SearchViewState.resolve(
      ref,
      mode: _mode,
      isExternal: isExternal,
      l10n: l10n,
      resolveDisplayBooks: _resolveDisplayBooks,
    );
    final isFullTextMode = _mode == SearchMode.fulltext && !isExternal;
    final isArticleMode = _mode == SearchMode.article && !isExternal;

    // Whether the results list is the branch on screen: the header
    // only folds away while results are shown. On the empty /
    // skeleton / error branches there is nothing to scroll, so the
    // header is forced visible there instead of getting stuck folded
    // away. SearchBodyView 用同一判定走分支，这里传下去。
    final showResults =
        !(_isQueryEmpty && _filters.categoryId == null) &&
        view.hasSearched &&
        !view.isLoading &&
        !view.loginRequired &&
        !(view.error != null && view.resultCount == 0) &&
        view.resultCount != 0;

    return Scaffold(
      body: SafeArea(
        top: true,
        bottom: false,
        // 2026-11-20:顶部改悬浮毛玻璃遮罩(与首页同款,blurEnabled
        // 门控)——结果区铺满全屏从头部底下穿过,滚动时搜索框/chips
        // 后面是实时模糊的结果流。
        child: Stack(
          children: [
            Positioned.fill(
              child: ValueListenableBuilder<double>(
                valueListenable: _glassHeaderHeight,
                builder: (context, headerHeight, child) => AnimatedPadding(
                  duration: AppMotion.standard,
                  padding: EdgeInsets.only(top: headerHeight),
                  child: child!,
                ),
                child: SearchBodyView(
                  l10n: l10n,
                  adaptiveGridColumns: adaptiveGrid,
                  isQueryEmpty: _isQueryEmpty,
                  categoryPicked: _filters.categoryId != null,
                  hasSearched: view.hasSearched,
                  isLoading: view.isLoading,
                  isLoadingMore: view.isLoadingMore,
                  loginRequired: view.loginRequired,
                  error: view.error,
                  resultCount: view.resultCount,
                  showResults: showResults,
                  isListViewListenable: _isListView,
                  onToggleView: () => _isListView.value = !_isListView.value,
                  onScrollNotification: _scrollHandler.onScrollNotification,
                  currentPage: view.currentPage,
                  totalPagesText: view.totalPagesText,
                  isFullTextMode: isFullTextMode,
                  isArticleMode: isArticleMode,
                  books: view.books,
                  hits: view.hits,
                  articles: view.articles,
                  recentSearches: _recentSearches.searches,
                  onSearchAgain: _searchAgain,
                  onRemoveRecentSearch: _removeRecentSearch,
                  onClearRecentSearches: _clearRecentSearches,
                  onOpenBook: _openBook,
                  onOpenFullTextHit: _openFullTextHit,
                  onOpenArticle: _openArticle,
                  onRetryLoadMore: _loadMore,
                  onRetrySearch: _performSearch,
                  onOpenLogin: () => AppRoutes.openLogin(context),
                ),
              ),
            ),
            // 毛玻璃遮罩头部(与首页同款,blurEnabled 门控):搜索框 +
            // 建议面板 + chips;结果从它底下穿过,滚动时头部后面是实时
            // 模糊的结果流。头部高度/建议窗口/chips 折叠都在头部组件
            // 内部消化(见 SearchGlassHeader 文档)。
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SearchGlassHeader(
                l10n: l10n,
                controller: _searchController,
                focusNode: _searchFocus,
                isExternal: isExternal,
                mode: _mode,
                source: _source,
                activeFilterCount: _filters.activeFilterCount(_mode),
                isQueryEmpty: _isQueryEmpty,
                lastSubmittedQuery: _lastSubmittedQuery,
                headerVisibleListenable: _scrollHandler.headerVisible,
                showResults: showResults,
                languageNames: languageNames,
                orderNames: orderNames,
                extensionNames: extensionNames,
                selectedLanguage: _filters.language,
                selectedOrder: _filters.order,
                selectedExtension: _filters.extension,
                selectedYearFrom: _filters.yearFrom,
                selectedYearTo: _filters.yearTo,
                exact: _filters.exactFor(_mode),
                selectedCategoryName: _filters.categoryName,
                selectedContentType: _filters.contentType,
                onSubmitted: _performSearch,
                onFilterTap: _openFilterDialogForCurrentLocale,
                onClear: _clearSearch,
                onScanTap: _openBarcodeScanner,
                onSelectSuggestion: (text) {
                  _searchController.text = text;
                  _searchController.selection = TextSelection.collapsed(
                    offset: text.length,
                  );
                  _performSearch();
                },
                onHeightChanged: (height) => _glassHeaderHeight.value = height,
                onSwitchSource: _switchSource,
                onSwitchMode: _switchMode,
                onResetLanguage: _resetLanguageFilter,
                onResetOrder: _resetOrderFilter,
                onResetExtension: _resetExtensionFilter,
                onResetYearFrom: _resetYearFromFilter,
                onResetYearTo: _resetYearToFilter,
                onResetExact: _resetExactFilter,
                onResetCategory: _resetCategoryFilter,
                onResetContentType: _resetContentTypeFilter,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
