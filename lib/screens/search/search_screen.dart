import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import '../../providers/article_search_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/books_provider.dart';
import '../../providers/fulltext_search_provider.dart';
import 'widgets/active_filter_chips.dart';
import 'widgets/empty_query_view.dart';
import 'widgets/search_mode_selector.dart';
import 'widgets/search_bar_field.dart';
import 'widgets/search_filter_dialog.dart';
import 'widgets/search_results_view.dart';
import 'widgets/search_skeleton_grid.dart';
import 'widgets/search_suggestions_view.dart';
import 'widgets/source_selector.dart';
import '../reader/reader_screen.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/gradient_app_bar.dart';
import '../../widgets/update_dialog.dart';
import '../../models/display_book.dart';
import '../../routes/app_routes.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../constants/search_filters.dart';
import '../../services/google_suggest_api.dart';
import '../../providers/update_provider.dart';
import '../../services/hive_service.dart';

import '../../utils/app_log.dart';
import '../../utils/app_snack.dart';
const _recentSearchesKey = 'recent_search_keywords';
const _recentSearchesLimit = 12;

/// Arguments for opening the search screen scoped to one category:
/// the screen browses that category immediately (empty query). The
/// category pages are gone — category lives only inside search now,
/// so this is also what the book-detail category chips navigate to.
class SearchScreenArgs {
  final int categoryId;
  final String categoryName;

  const SearchScreenArgs({
    required this.categoryId,
    required this.categoryName,
  });
}

class SearchScreen extends ConsumerStatefulWidget {
  final BookSource? initialSource;

  /// Category to browse on open (empty query): set when the screen
  /// is opened from a book-detail category chip or the category
  /// picker. Null means a plain search screen.
  final int? initialCategoryId;
  final String? initialCategoryName;

  const SearchScreen({
    super.key,
    this.initialSource,
    this.initialCategoryId,
    this.initialCategoryName,
  });

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

/// Orchestrator only: owns the query state (controller, debounce,
/// suggestions), the applied filters and the recent-searches store, and
/// wires the zero-state presentation widgets from `widgets/` together.
class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _searchController = TextEditingController();

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

  // ── Filters (edited on the filter page, applied on 使用) ──
  String _selectedLanguage = 'all';
  String _selectedOrder = 'default';
  String _selectedExtension = 'all';
  int? _selectedYearFrom;
  int? _selectedYearTo;

  /// General-search exact match (`e=1`); full-text has its own
  /// [_fullTextExact] below.
  bool _generalExact = false;

  /// Category scope (general mode only): the picked category's id and
  /// localized display name. Set from the filter dialog, the category
  /// picker, or the constructor (detail-page chips). Null means the
  /// search is unscoped. Cleared on mode switch — a category belongs
  /// to the general search the way its sort default does.
  int? _selectedCategoryId;
  String? _selectedCategoryName;

  /// Content-type filter inside a category (`book` / `article`);
  /// null means any content type. Only meaningful while a category
  /// is picked — clearing the category clears this too.
  String? _selectedContentType;

  // ── z站 search mode: 通用 / 文章 / 全文检索. The full-text-only
  // extras (words/phrase match + exact flag) live below; their
  // default is `words` / off (the site's working default,
  // device-proven 2026-11-11). The order default differs per mode
  // ('popular' for full-text, 'default' for general and article
  // search) — see _switchMode.
  SearchMode _mode = SearchMode.general;
  String _fullTextMatchType = 'words';
  bool _fullTextExact = false;

  bool _isListView = false;
  bool _isQueryEmpty = true;
  List<String> _recentSearches = [];

  // Debounced Google suggestions while typing.
  final _suggestApi = GoogleSuggestApi();
  Timer? _suggestDebounce;
  List<String> _suggestions = [];
  bool _suggestionsLoading = false;
  bool _showSuggestions = false;
  String _lastSubmittedQuery = '';

  late BookSource _source;

  int get _activeFilterCount {
    switch (_mode) {
      case SearchMode.fulltext:
        // The full-text request DOES carry language / extension
        // (`/fulltext/?…&languages[]=…&extensions[]=…`, verified
        // end-to-end: search_screen → FullTextSearchParams →
        // ZLibraryFullText.searchFullText), and the page shows both
        // sections in this mode — so the badge counts them, same as
        // the general branch. Only article mode hides those filters.
        return (_selectedLanguage != 'all' ? 1 : 0) +
            (_selectedOrder != 'popular' ? 1 : 0) +
            (_selectedExtension != 'all' ? 1 : 0) +
            (_fullTextMatchType != 'words' ? 1 : 0) +
            (_fullTextExact ? 1 : 0) +
            (_selectedYearFrom != null ? 1 : 0) +
            (_selectedYearTo != null ? 1 : 0);
      case SearchMode.article:
        // Article search sends only the query and sort (v1) — the
        // page hides the language / extension sections so the UI
        // never promises a filter the request does not carry.
        return _selectedOrder != 'default' ? 1 : 0;
      case SearchMode.general:
        return (_selectedLanguage != 'all' ? 1 : 0) +
            (_selectedOrder != 'default' ? 1 : 0) +
            (_selectedExtension != 'all' ? 1 : 0) +
            (_selectedYearFrom != null ? 1 : 0) +
            (_selectedYearTo != null ? 1 : 0) +
            (_generalExact ? 1 : 0) +
            (_selectedCategoryId != null ? 1 : 0) +
            (_selectedContentType != null ? 1 : 0);
    }
  }

  @override
  void initState() {
    super.initState();
    _source = widget.initialSource ?? BookSource.zlibrary;
    _selectedCategoryId = widget.initialCategoryId;
    _selectedCategoryName = widget.initialCategoryName;
    final savedSearches = HiveService.settingsBox.get(_recentSearchesKey);
    if (savedSearches is List) {
      final seen = <String>{};
      _recentSearches = savedSearches
          .whereType<String>()
          .map((keyword) => keyword.trim())
          .where(
            (keyword) => keyword.isNotEmpty && seen.add(keyword.toLowerCase()),
          )
          .take(_recentSearchesLimit)
          .toList();
    }
    _searchController.addListener(_onQueryChanged);
    // Opened with a category (detail-page chip): browse it
    // immediately — an empty query plus a category is a browse, not
    // an empty page.
    if (_selectedCategoryId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _runSearch();
      });
    }
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _searchController.removeListener(_onQueryChanged);
    _searchController.dispose();
    super.dispose();
  }

  // ── Suggestions ──────────────────────────────────────────────

  void _onQueryChanged() {
    final text = _searchController.text.trim();
    final isEmpty = text.isEmpty;
    final showSuggestions = !isEmpty && text != _lastSubmittedQuery;
    if (isEmpty != _isQueryEmpty || showSuggestions != _showSuggestions) {
      setState(() {
        _isQueryEmpty = isEmpty;
        _showSuggestions = showSuggestions;
      });
    }
    _scheduleSuggestions(text);
  }

  void _scheduleSuggestions(String query) {
    _suggestDebounce?.cancel();
    if (query.isEmpty || query == _lastSubmittedQuery) {
      if (_suggestions.isNotEmpty || _suggestionsLoading) {
        setState(() {
          _suggestions = [];
          _suggestionsLoading = false;
        });
      }
      return;
    }
    _suggestDebounce = Timer(const Duration(milliseconds: 350), () {
      _fetchSuggestions(query);
    });
  }

  Future<void> _fetchSuggestions(String query) async {
    if (!mounted) return;
    if (query == _lastSubmittedQuery) return;
    setState(() => _suggestionsLoading = true);
    final results = await _suggestApi.fetchSuggestions(query);
    if (!mounted) return;
    if (_searchController.text.trim() != query ||
        query == _lastSubmittedQuery) {
      return;
    }
    setState(() {
      _suggestions = results;
      _suggestionsLoading = false;
    });
  }

  // ── Recent searches ──────────────────────────────────────────

  Future<void> _saveRecentSearches(List<String> searches) async {
    setState(() => _recentSearches = searches);
    try {
      await HiveService.settingsBox.put(_recentSearchesKey, searches);
    } catch (error) {
      AppLog.report(
        'Failed to save recent searches: ${error.runtimeType}',
        tag: 'search_screen',
      );
      if (mounted) {
        showAppSnack(context,
              AppLocalizations.of(context)!.searchHistorySaveFailed,
            );
      }
    }
  }

  void _rememberSearch(String query) {
    final normalized = query.toLowerCase();
    final searches = [
      query,
      ..._recentSearches.where((item) => item.toLowerCase() != normalized),
    ].take(_recentSearchesLimit).toList();
    unawaited(_saveRecentSearches(searches));
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
    unawaited(
      _saveRecentSearches(
        _recentSearches.where((item) => item != keyword).toList(),
      ),
    );
  }

  void _clearRecentSearches() {
    unawaited(_saveRecentSearches([]));
  }

  /// Fill the field with a suggestion without searching (the trailing
  /// arrow in the suggestions view).
  void _insertSuggestion(String suggestion) {
    _searchController.text = suggestion;
    _searchController.selection = TextSelection.collapsed(
      offset: suggestion.length,
    );
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _lastSubmittedQuery = '');
    ref.read(searchProvider.notifier).reset();
    ref.read(fulltextSearchProvider.notifier).reset();
    ref.read(articleSearchProvider.notifier).reset();
    ref.read(externalSearchProvider.notifier).reset();
    // A picked category survives clearing the query: empty query
    // plus a category is a browse, so go back to browsing it (the
    // old category screen's clear-search did the same) — but only
    // in the z站 general search, where a category means anything.
    if (_selectedCategoryId != null &&
        _source == BookSource.zlibrary &&
        _mode == SearchMode.general) {
      _runSearch();
    }
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
        ? _selectedCategoryId != null
        : query == _lastSubmittedQuery;
    if (canRun) _performSearch();
  }

  void _resetLanguageFilter() {
    _selectedLanguage = 'all';
    _applyFilterChange();
  }

  void _resetOrderFilter() {
    _selectedOrder = _mode == SearchMode.fulltext ? 'popular' : 'default';
    _applyFilterChange();
  }

  void _resetExtensionFilter() {
    _selectedExtension = 'all';
    _applyFilterChange();
  }

  void _resetYearFromFilter() {
    _selectedYearFrom = null;
    _applyFilterChange();
  }

  void _resetYearToFilter() {
    _selectedYearTo = null;
    _applyFilterChange();
  }

  void _resetExactFilter() {
    if (_mode == SearchMode.fulltext) {
      _fullTextExact = false;
    } else {
      _generalExact = false;
    }
    _applyFilterChange();
  }

  /// Clear the category scope (and the content type, which only
  /// exists inside a category). With an empty query the stale
  /// category results are dropped too, so the empty-query view shows
  /// again; with a submitted query the search re-runs unscoped.
  void _resetCategoryFilter() {
    _selectedCategoryId = null;
    _selectedCategoryName = null;
    _selectedContentType = null;
    if (_searchController.text.trim().isEmpty) {
      ref.read(searchProvider.notifier).reset();
    }
    _applyFilterChange();
  }

  void _resetContentTypeFilter() {
    _selectedContentType = null;
    _applyFilterChange();
  }

  /// The filter button in the search bar: opens the filter dialog
  /// with the current locale's display names (same maps the chips
  /// mirror). Article mode passes empty language / extension maps —
  /// their rows hide (the request carries none of those filters).
  /// The dialog stages edits and only returns them when 使用 is
  /// tapped; closing discards.
  void _openFilterDialogForCurrentLocale() {
    final locale = Localizations.localeOf(context).languageCode;
    final isArticle = _mode == SearchMode.article;
    unawaited(
      _openFilterDialog(
        isArticle
            ? const <String, String>{}
            : getLanguageDisplayNames(locale),
        _mode == SearchMode.fulltext
            ? getFulltextOrderDisplayNames(locale)
            : getOrderDisplayNames(locale),
        isArticle
            ? const <String, String>{}
            : getExtensionDisplayNames(locale),
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
        language: _selectedLanguage,
        order: _selectedOrder,
        extension: _selectedExtension,
        yearFrom: _selectedYearFrom,
        yearTo: _selectedYearTo,
        exact: _mode == SearchMode.fulltext
            ? _fullTextExact
            : _generalExact,
        matchType: _fullTextMatchType,
        contentType: _selectedContentType,
        categoryId: _selectedCategoryId,
        categoryName: _selectedCategoryName,
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
    _selectedLanguage = result.language;
    _selectedOrder = result.order;
    _selectedExtension = result.extension;
    _selectedYearFrom = result.yearFrom;
    _selectedYearTo = result.yearTo;
    if (_mode == SearchMode.fulltext) {
      _fullTextExact = result.exact;
      _fullTextMatchType = result.matchType;
    } else {
      _generalExact = result.exact;
    }
    _selectedCategoryId = result.categoryId;
    _selectedCategoryName = result.categoryName;
    _selectedContentType = result.contentType;
    _applyFilterChange();
  }

  /// The "Browse Categories" row of the empty-query view: the
  /// searchable category picker. Picking one scopes the search to
  /// it and browses it immediately (empty query plus a category is
  /// a browse); dismissing picks nothing. A category only exists in
  /// the z站 general search, so picking one comes back to it first
  /// (both switches reset their providers; the category is set
  /// after them because a mode switch clears it).
  Future<void> _openCategoryPicker() async {
    final picked = await showDialog<PickedCategory?>(
      context: context,
      builder: (context) => CategoryPickerDialog(
        currentId: _selectedCategoryId,
        showAllOption: false,
      ),
    );
    if (picked == null || picked.id == null || !mounted) return;
    if (_source != BookSource.zlibrary) {
      _switchSource(BookSource.zlibrary);
    }
    if (_mode != SearchMode.general) _switchMode(SearchMode.general);
    setState(() {
      _selectedCategoryId = picked.id;
      _selectedCategoryName = picked.name;
      // A newly picked category starts unfiltered.
      _selectedContentType = null;
    });
    _runSearch();
  }

  // ── Search execution ─────────────────────────────────────────

  void _performSearch() {
    final query = _searchController.text.trim();
    // An empty query is a browse, not a no-op, when a category is
    // picked — but it is never remembered as a recent search, and it
    // only browses in the z站 general search (a category means
    // nothing on another source or mode).
    final canBrowseCategory = _selectedCategoryId != null &&
        _source == BookSource.zlibrary &&
        _mode == SearchMode.general;
    if (query.isEmpty && !canBrowseCategory) return;
    setState(() {
      _lastSubmittedQuery = query;
      _suggestions = [];
      _suggestionsLoading = false;
      _showSuggestions = false;
    });
    if (_runSearch() && query.isNotEmpty) _rememberSearch(query);
  }

  bool _runSearch() {
    if (ref.read(updateProvider).isBlocked) {
      unawaited(showUpdateDialog(context));
      return false;
    }

    final query = _searchController.text.trim();
    if (_source != BookSource.zlibrary) {
      ref.read(externalSearchProvider.notifier).search(query, _source);
      return true;
    }

    if (_mode == SearchMode.fulltext) {
      ref.read(fulltextSearchProvider.notifier).search(
        FullTextSearchParams(
          query: query,
          type: _fullTextMatchType,
          exact: _fullTextExact,
          yearFrom: _selectedYearFrom,
          yearTo: _selectedYearTo,
          languages: searchLanguages[_selectedLanguage] != null
              ? [searchLanguages[_selectedLanguage]!]
              : null,
          extensions: searchExtensions[_selectedExtension] != null
              ? [searchExtensions[_selectedExtension]!]
              : null,
          order: _selectedOrder,
        ),
      );
      return true;
    }

    if (_mode == SearchMode.article) {
      ref.read(articleSearchProvider.notifier).search(
        ArticleSearchParams(
          query: query,
          order: searchOrders[_selectedOrder],
        ),
      );
      return true;
    }

    // A picked category scopes the general search to the category
    // HTML routes (browse when the query is empty, in-category
    // search otherwise) with the same filters the old category
    // screen passed; without one it is the plain eapi search.
    if (_selectedCategoryId != null) {
      ref.read(searchProvider.notifier).search(
        SearchParams(
          query: query,
          yearFrom: _selectedYearFrom,
          yearTo: _selectedYearTo,
          languages: searchLanguages[_selectedLanguage] != null
              ? [searchLanguages[_selectedLanguage]!]
              : null,
          extensions: searchExtensions[_selectedExtension] != null
              ? [searchExtensions[_selectedExtension]!]
              : null,
          order: searchOrders[_selectedOrder],
          exact: _generalExact,
          categoryId: _selectedCategoryId,
          contentTypes: _selectedContentType == null
              ? null
              : [_selectedContentType!],
        ),
      );
      return true;
    }

    ref
        .read(searchProvider.notifier)
        .search(
          SearchParams(
            query: query,
            yearFrom: _selectedYearFrom,
            yearTo: _selectedYearTo,
            languages: searchLanguages[_selectedLanguage] != null
                ? [searchLanguages[_selectedLanguage]!]
                : null,
            extensions: searchExtensions[_selectedExtension] != null
                ? [searchExtensions[_selectedExtension]!]
                : null,
            order: searchOrders[_selectedOrder],
            exact: _generalExact,
          ),
        );
    return true;
  }

  void _switchSource(BookSource source) {
    if (source == _source) return;
    setState(() {
      _source = source;
      _suggestions = [];
      _suggestionsLoading = false;
      _showSuggestions = false;
      _lastSubmittedQuery = '';
    });
    ref.read(searchProvider.notifier).reset();
    ref.read(fulltextSearchProvider.notifier).reset();
    ref.read(articleSearchProvider.notifier).reset();
    ref.read(externalSearchProvider.notifier).reset();
    if (_searchController.text.trim().isNotEmpty) {
      _performSearch();
    } else if (_selectedCategoryId != null &&
        source == BookSource.zlibrary) {
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
      _selectedOrder = mode == SearchMode.fulltext ? 'popular' : 'default';
      _selectedCategoryId = null;
      _selectedCategoryName = null;
      _selectedContentType = null;
      _suggestions = [];
      _suggestionsLoading = false;
      _showSuggestions = false;
      _lastSubmittedQuery = '';
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

  /// 滚动加载走气泡通知（结果区在 [SearchResultsView] 外由调用处包
  /// NotificationListener）：不再需要 ScrollController，网格↔列表
  /// 切换的 AnimatedSwitcher 过渡期间新旧两个列表才能同时在树上。
  /// 阈值与原 controller 监听一致；重复触发由各 provider 的
  /// isLoadingMore / totalPages 守卫兜底。
  bool _onScrollNotification(ScrollNotification n) {
    if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
      _loadMore();
    }
    return false;
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
    final languageNames = getLanguageDisplayNames(locale);
    final orderNames = _mode == SearchMode.fulltext
        ? getFulltextOrderDisplayNames(locale)
        : getOrderDisplayNames(locale);
    final extensionNames = getExtensionDisplayNames(locale);
    final isExternal = _source != BookSource.zlibrary;

    final searchState = ref.watch(searchProvider);
    final externalState = ref.watch(externalSearchProvider);
    final fulltextState = ref.watch(fulltextSearchProvider);
    final articleState = ref.watch(articleSearchProvider);
    final isFullTextMode = _mode == SearchMode.fulltext && !isExternal;
    final isArticleMode = _mode == SearchMode.article && !isExternal;
    final books = isExternal
        ? externalState.books
        : _resolveDisplayBooks(searchState.books);
    final resultCount = isFullTextMode
        ? fulltextState.hits.length
        : isArticleMode
        ? articleState.articles.length
        : books.length;
    final hasSearched = isExternal
        ? externalState.hasSearched
        : isFullTextMode
        ? fulltextState.hasSearched
        : isArticleMode
        ? articleState.hasSearched
        : searchState.hasSearched;
    final isLoading = isExternal
        ? externalState.isLoading
        : isFullTextMode
        ? fulltextState.isLoading
        : isArticleMode
        ? articleState.isLoading
        : searchState.isLoading;
    final isLoadingMore = isExternal
        ? externalState.isLoadingMore
        : isFullTextMode
        ? fulltextState.isLoadingMore
        : isArticleMode
        ? articleState.isLoadingMore
        : searchState.isLoadingMore;
    final loginRequired = isFullTextMode && fulltextState.loginRequired;
    final error = isExternal
        ? externalState.error
        : isFullTextMode
        ? (fulltextState.error == fulltextTokenUnavailable
              ? l10n.fullTextUnavailable
              : fulltextState.error)
        : isArticleMode
        ? articleState.error
        : searchState.error;
    final currentPage = isExternal
        ? externalState.currentPage
        : isFullTextMode
        ? fulltextState.currentPage
        : isArticleMode
        ? articleState.currentPage
        : searchState.currentPage;
    final totalPagesText = isExternal
        ? (externalState.hasMore ? '…' : '${externalState.currentPage}')
        : isFullTextMode
        ? '${fulltextState.totalPages}'
        : isArticleMode
        ? '${articleState.totalPages}'
        : searchState.totalPagesUnknown
        ? '…'
        : '${searchState.totalPages}';

    return Scaffold(
      appBar: GradientAppBar(title: l10n.searchBooks),
      body: Column(
        children: [
          SearchBarField(
            l10n: l10n,
            controller: _searchController,
            isExternal: isExternal,
            activeFilterCount: _activeFilterCount,
            isQueryEmpty: _isQueryEmpty,
            hintText: _mode == SearchMode.fulltext
                ? l10n.fullTextSearchHint
                : null,
            onSubmitted: _performSearch,
            onFilterTap: _openFilterDialogForCurrentLocale,
            onClear: _clearSearch,
          ),
          SearchSourceSelector(
            l10n: l10n,
            selected: _source,
            onSwitch: _switchSource,
          ),
          if (!isExternal)
            SearchModeSelector(
              l10n: l10n,
              mode: _mode,
              onSwitch: _switchMode,
            ),
          if (!isExternal && _activeFilterCount > 0)
            SearchActiveFilterChips(
              l10n: l10n,
              mode: _mode,
              languageNames: languageNames,
              orderNames: orderNames,
              extensionNames: extensionNames,
              contentTypeNames: {
                'book': l10n.contentTypeBook,
                'article': l10n.contentTypeArticle,
              },
              selectedLanguage: _selectedLanguage,
              selectedOrder: _selectedOrder,
              selectedExtension: _selectedExtension,
              selectedYearFrom: _selectedYearFrom,
              selectedYearTo: _selectedYearTo,
              exact: _mode == SearchMode.fulltext
                  ? _fullTextExact
                  : _generalExact,
              selectedCategoryName: _selectedCategoryName,
              selectedContentType: _selectedContentType,
              onResetLanguage: _resetLanguageFilter,
              onResetOrder: _resetOrderFilter,
              onResetExtension: _resetExtensionFilter,
              onResetYearFrom: _resetYearFromFilter,
              onResetYearTo: _resetYearToFilter,
              onResetExact: _resetExactFilter,
              onResetCategory: _resetCategoryFilter,
              onResetContentType: _resetContentTypeFilter,
            ),
          Expanded(
            child: _isQueryEmpty && _selectedCategoryId == null
                ? SearchEmptyQueryView(
                    l10n: l10n,
                    recentSearches: _recentSearches,
                    onSearch: _searchAgain,
                    onRemoveSearch: _removeRecentSearch,
                    onClearHistory: _clearRecentSearches,
                    onBrowseCategories: _openCategoryPicker,
                  )
                : _showSuggestions
                ? SearchSuggestionsView(
                    l10n: l10n,
                    suggestions: _suggestions,
                    isLoading: _suggestionsLoading,
                    query: _searchController.text.trim(),
                    onSearch: _searchAgain,
                    onInsert: _insertSuggestion,
                  )
                : !hasSearched
                ? EmptyState(
                    icon: Icons.search_rounded,
                    title: l10n.startSearching,
                    message: l10n.enterSearchHint,
                  )
                : isLoading
                ? const SearchSkeletonGrid()
                : loginRequired
                ? EmptyState(
                    icon: Icons.login_rounded,
                    title: l10n.fullTextLoginRequired,
                    action: FilledButton(
                      onPressed: () => AppRoutes.openLogin(context),
                      child: Text(l10n.login),
                    ),
                  )
                : error != null && resultCount == 0
                ? EmptyState(
                    icon: Icons.error_outline_rounded,
                    title: l10n.searchFailed,
                    message: error,
                    action: FilledButton(
                      onPressed: _performSearch,
                      child: Text(l10n.searchRetry),
                    ),
                  )
                : resultCount == 0
                ? EmptyState(
                    icon: Icons.search_off_rounded,
                    title: l10n.noResults,
                    message: l10n.searchNoResultsSwitch,
                  )
                // 滚动加载用气泡通知监听（见 _onScrollNotification）：
                // 只包住结果分支，空态/建议页的滚动不会误触发加载。
                : NotificationListener<ScrollNotification>(
                    onNotification: _onScrollNotification,
                    child: SearchResultsView(
                      l10n: l10n,
                      resultCount: resultCount,
                      currentPage: currentPage,
                      totalPagesText: totalPagesText,
                      isListView: _isListView,
                      onToggleView: () =>
                          setState(() => _isListView = !_isListView),
                      error: error,
                      isLoadingMore: isLoadingMore,
                      isFullTextMode: isFullTextMode,
                      isArticleMode: isArticleMode,
                      books: books,
                      hits: fulltextState.hits,
                      articles: articleState.articles,
                      onOpenBook: _openBook,
                      onOpenFullTextHit: _openFullTextHit,
                      onOpenArticle: _openArticle,
                      onRetryLoadMore: _loadMore,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
