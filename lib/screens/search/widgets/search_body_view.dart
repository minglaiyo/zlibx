import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart'
    show Article, Book, FullTextHit, fulltextTokenUnavailable;

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/display_book.dart';
import '../../../providers/article_search_provider.dart';
import '../../../providers/books_provider.dart';
import '../../../providers/fulltext_search_provider.dart';
import '../../../widgets/empty_state.dart';
import 'empty_query_view.dart';
import 'search_mode_selector.dart';
import 'search_results_view.dart';
import 'search_skeleton_grid.dart';

/// 四个源（通用 / 文章 / 全文 / 外部）的"当前态"归一（审查 B2 拆分）：
/// 从 SearchScreen.build 的五路 watch 三元阶梯提炼，字段语义与拆分前
/// 逐字一致（含全文 token 不可用时的错误文案替换）。
class SearchViewState {
  const SearchViewState({
    this.books = const [],
    this.hits = const [],
    this.articles = const [],
    this.resultCount = 0,
    this.hasSearched = false,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.loginRequired = false,
    this.error,
    this.currentPage = 1,
    this.totalPagesText = '',
  });

  final List<DisplayBook> books;
  final List<FullTextHit> hits;
  final List<Article> articles;
  final int resultCount;
  final bool hasSearched;
  final bool isLoading;
  final bool isLoadingMore;
  final bool loginRequired;
  final String? error;
  final int currentPage;
  final String totalPagesText;

  static SearchViewState resolve(
    WidgetRef ref, {
    required SearchMode mode,
    required bool isExternal,
    required AppLocalizations l10n,
    required List<DisplayBook> Function(List<Book> books)
    resolveDisplayBooks,
  }) {
    final searchState = ref.watch(searchProvider);
    final externalState = ref.watch(externalSearchProvider);
    final fulltextState = ref.watch(fulltextSearchProvider);
    final articleState = ref.watch(articleSearchProvider);
    final isFullTextMode = mode == SearchMode.fulltext && !isExternal;
    final isArticleMode = mode == SearchMode.article && !isExternal;
    final books = isExternal
        ? externalState.books
        : resolveDisplayBooks(searchState.books);
    return SearchViewState(
      books: books,
      hits: fulltextState.hits,
      articles: articleState.articles,
      resultCount: isFullTextMode
          ? fulltextState.hits.length
          : isArticleMode
          ? articleState.articles.length
          : books.length,
      hasSearched: isExternal
          ? externalState.hasSearched
          : isFullTextMode
          ? fulltextState.hasSearched
          : isArticleMode
          ? articleState.hasSearched
          : searchState.hasSearched,
      isLoading: isExternal
          ? externalState.isLoading
          : isFullTextMode
          ? fulltextState.isLoading
          : isArticleMode
          ? articleState.isLoading
          : searchState.isLoading,
      isLoadingMore: isExternal
          ? externalState.isLoadingMore
          : isFullTextMode
          ? fulltextState.isLoadingMore
          : isArticleMode
          ? articleState.isLoadingMore
          : searchState.isLoadingMore,
      loginRequired: isFullTextMode && fulltextState.loginRequired,
      error: isExternal
          ? externalState.error
          : isFullTextMode
          ? (fulltextState.error == fulltextTokenUnavailable
                ? l10n.fullTextUnavailable
                : fulltextState.error)
          : isArticleMode
          ? articleState.error
          : searchState.error,
      currentPage: isExternal
          ? externalState.currentPage
          : isFullTextMode
          ? fulltextState.currentPage
          : isArticleMode
          ? articleState.currentPage
          : searchState.currentPage,
      totalPagesText: isExternal
          ? (externalState.hasMore ? '…' : '${externalState.currentPage}')
          : isFullTextMode
          ? '${fulltextState.totalPages}'
          : isArticleMode
          ? '${articleState.totalPages}'
          : searchState.totalPagesUnknown
          ? '…'
          : '${searchState.totalPages}',
    );
  }
}

/// 结果区/空态分支梯（审查 B2 拆分，2026-11-21）：从 SearchScreen 的
/// build 里搬出，分支判定条件与拆分前逐字一致。`showResults` 由屏幕
/// 按同一表达式算好传入（头部折叠也用它），是"走到结果分支"的唯一
/// 判定，这里不重算。
///
/// 结果分支外包 NotificationListener（滚动加载 + 头部折叠走气泡通
/// 知），空态/建议页的滚动不会误触发加载。网格↔列表切换的
/// AnimatedSwitcher 过渡期间新旧两个列表同时在树上——监听不持
/// ScrollController 正是为了这个。
class SearchBodyView extends StatelessWidget {
  const SearchBodyView({
    super.key,
    required this.l10n,
    required this.adaptiveGridColumns,
    required this.isQueryEmpty,
    required this.categoryPicked,
    required this.hasSearched,
    required this.isLoading,
    required this.isLoadingMore,
    required this.loginRequired,
    required this.error,
    required this.resultCount,
    required this.showResults,
    required this.isListViewListenable,
    required this.onToggleView,
    required this.onScrollNotification,
    required this.currentPage,
    required this.totalPagesText,
    required this.isFullTextMode,
    required this.isArticleMode,
    required this.books,
    required this.hits,
    required this.articles,
    required this.recentSearches,
    required this.onSearchAgain,
    required this.onRemoveRecentSearch,
    required this.onClearRecentSearches,
    required this.onOpenBook,
    required this.onOpenFullTextHit,
    required this.onOpenArticle,
    required this.onRetryLoadMore,
    required this.onRetrySearch,
    required this.onOpenLogin,
  });

  final AppLocalizations l10n;
  final bool adaptiveGridColumns;
  final bool isQueryEmpty;
  final bool categoryPicked;
  final bool hasSearched;
  final bool isLoading;
  final bool isLoadingMore;
  final bool loginRequired;
  final String? error;
  final int resultCount;

  /// true = 走结果分支（屏幕用同一表达式算出，见 SearchScreen.build）。
  final bool showResults;

  /// 网格↔列表切换。ValueListenable：切换只重建结果区这一层。
  final ValueListenable<bool> isListViewListenable;
  final VoidCallback onToggleView;
  final bool Function(ScrollNotification notification) onScrollNotification;

  final int currentPage;
  final String totalPagesText;
  final bool isFullTextMode;
  final bool isArticleMode;
  final List<DisplayBook> books;
  final List<FullTextHit> hits;
  final List<Article> articles;

  final List<String> recentSearches;
  final ValueChanged<String> onSearchAgain;
  final ValueChanged<String> onRemoveRecentSearch;
  final VoidCallback onClearRecentSearches;

  final ValueChanged<DisplayBook> onOpenBook;
  final ValueChanged<FullTextHit> onOpenFullTextHit;
  final ValueChanged<Article> onOpenArticle;
  final VoidCallback onRetryLoadMore;
  final VoidCallback onRetrySearch;
  final VoidCallback onOpenLogin;

  @override
  Widget build(BuildContext context) {
    if (showResults) {
      // 滚动加载用气泡通知监听：只包住结果分支，空态/建议页的滚动
      // 不会误触发加载。
      return NotificationListener<ScrollNotification>(
        onNotification: onScrollNotification,
        child: ValueListenableBuilder<bool>(
          valueListenable: isListViewListenable,
          builder: (context, isListView, _) => SearchResultsView(
            adaptiveGridColumns: adaptiveGridColumns,
            l10n: l10n,
            resultCount: resultCount,
            currentPage: currentPage,
            totalPagesText: totalPagesText,
            isListView: isListView,
            onToggleView: onToggleView,
            error: error,
            isLoadingMore: isLoadingMore,
            isFullTextMode: isFullTextMode,
            isArticleMode: isArticleMode,
            books: books,
            hits: hits,
            articles: articles,
            onOpenBook: onOpenBook,
            onOpenFullTextHit: onOpenFullTextHit,
            onOpenArticle: onOpenArticle,
            onRetryLoadMore: onRetryLoadMore,
          ),
        ),
      );
    }
    if (isQueryEmpty && !categoryPicked) {
      return SearchEmptyQueryView(
        l10n: l10n,
        recentSearches: recentSearches,
        onSearch: onSearchAgain,
        onRemoveSearch: onRemoveRecentSearch,
        onClearHistory: onClearRecentSearches,
      );
    }
    if (!hasSearched) {
      return EmptyState(
        icon: Icons.search_rounded,
        title: l10n.startSearching,
        message: l10n.enterSearchHint,
      );
    }
    if (isLoading) {
      return SearchSkeletonGrid(adaptiveGridColumns: adaptiveGridColumns);
    }
    if (loginRequired) {
      return EmptyState(
        icon: Icons.login_rounded,
        title: l10n.fullTextLoginRequired,
        action: FilledButton(
          onPressed: onOpenLogin,
          child: Text(l10n.login),
        ),
      );
    }
    if (error != null && resultCount == 0) {
      return EmptyState(
        icon: Icons.error_outline_rounded,
        title: l10n.searchFailed,
        message: error,
        action: FilledButton(
          onPressed: onRetrySearch,
          child: Text(l10n.searchRetry),
        ),
      );
    }
    // resultCount == 0（能走到这说明 showResults == false 且前面都
    // 不匹配）。
    return EmptyState(
      icon: Icons.search_off_rounded,
      title: l10n.noResults,
      message: l10n.searchNoResultsSwitch,
    );
  }
}
