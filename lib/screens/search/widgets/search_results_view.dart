import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/display_book.dart';
import '../../../widgets/book_card.dart';
import '../../../widgets/book_quick_actions_sheet.dart';
import '../../../widgets/book_list_tile.dart';
import '../../../widgets/entrance.dart';
import '../../../widgets/loading_widget.dart';
import '../../../widgets/state_transition_switch.dart';
import 'article_tile.dart';
import 'fulltext_hit_tile.dart';

/// Search 结果区：结果数 / 页码 / 视图切换头 + 加载更多失败横幅 +
/// 四种结果列表（全文 / 文章 / 书本列表 / 书本网格）。
///
/// 从 search_screen 抽出（此前 1007 行编排页里约 260 行是这段展示
/// 逻辑）。三处视觉/动效升级：
/// 1. 网格↔列表切换由硬切改为 [StateTransitionSwitch] 淡入淡出——
///    四个分支各自带互不相同的 Key，模式间切换同样有过渡；
/// 2. 每种结果条目接入一次性进场动画（[EntranceSlideFade]，前 8 条
///    错峰入场，滚动加载的新条目不再触发，尊重系统关闭动画设置）；
/// 3. 滚动加载监听从 ScrollController 换成交接页编排的
///    NotificationListener——AnimatedSwitcher 过渡期间新旧两个列表
///    同时在树上，一个 ScrollController 不能同时挂两个 ScrollPosition，
///    气泡通知则天然没有这个限制。
class SearchResultsView extends StatelessWidget {
  const SearchResultsView({
    super.key,
    required this.l10n,
    required this.resultCount,
    required this.currentPage,
    required this.totalPagesText,
    required this.isListView,
    required this.onToggleView,
    required this.onRetryLoadMore,
    required this.books,
    required this.hits,
    required this.articles,
    required this.onOpenBook,
    required this.onOpenFullTextHit,
    required this.onOpenArticle,
    this.error,
    this.isLoadingMore = false,
    this.isFullTextMode = false,
    this.isArticleMode = false,
  });

  final AppLocalizations l10n;

  /// 当前分支的结果总数（fulltext=hits / article=articles / 其余=books）。
  final int resultCount;

  final int currentPage;

  /// 页码展示文本（外部源还有下一页时为 '…'）。
  final String totalPagesText;

  final bool isListView;

  /// 网格↔列表切换（仅书本分支展示按钮）。
  final VoidCallback onToggleView;

  /// 加载更多失败但已有结果时的错误文本；null 不显示横幅。
  final String? error;

  final bool isLoadingMore;

  final bool isFullTextMode;

  final bool isArticleMode;

  /// 书本分支的结果（外部源与 z站 通用搜索共用）。
  final List<DisplayBook> books;

  final List<FullTextHit> hits;

  final List<Article> articles;

  final ValueChanged<DisplayBook> onOpenBook;
  final ValueChanged<FullTextHit> onOpenFullTextHit;
  final ValueChanged<Article> onOpenArticle;

  /// 「重试」加载更多。
  final VoidCallback onRetryLoadMore;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _header(context),
        if (error != null) _loadMoreErrorBanner(context),
        Expanded(
          child: StateTransitionSwitch(
            child: isFullTextMode
                ? _fullTextList(context)
                : isArticleMode
                ? _articleList(context)
                : isListView
                ? _bookList(context)
                : _bookGrid(context),
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              l10n.searchResultsCount(resultCount),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: cs.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.searchPageProgress(currentPage, totalPagesText),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          // 文章/全文模式没有网格卡片，视图切换只对书本分支有意义。
          if (!isFullTextMode && !isArticleMode)
            IconButton(
              icon: Icon(
                isListView ? Icons.grid_view_rounded : Icons.view_list_rounded,
                color: cs.primary,
                size: 22,
              ),
              tooltip: isListView ? l10n.gridView : l10n.listView,
              onPressed: onToggleView,
            ),
        ],
      ),
    );
  }

  /// 加载更多失败但已有结果：横幅提示 + 重试（不清空已有结果）。
  Widget _loadMoreErrorBanner(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(child: Text(l10n.searchMoreFailed)),
          TextButton(
            onPressed: onRetryLoadMore,
            child: Text(l10n.searchRetry),
          ),
        ],
      ),
    );
  }

  Widget _fullTextList(BuildContext context) {
    return ListView.builder(
      key: const ValueKey('fulltext'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: hits.length + (isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= hits.length) {
          return const LoadingWidget.more();
        }
        final hit = hits[index];
        return EntranceSlideFade(
          index: index,
          child: FullTextHitTile(
            hit: hit,
            l10n: l10n,
            onTap: () => onOpenFullTextHit(hit),
          ),
        );
      },
    );
  }

  Widget _articleList(BuildContext context) {
    return ListView.builder(
      key: const ValueKey('article'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: articles.length + (isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= articles.length) {
          return const LoadingWidget.more();
        }
        final article = articles[index];
        return EntranceSlideFade(
          index: index,
          child: ArticleTile(
            article: article,
            l10n: l10n,
            onTap: () => onOpenArticle(article),
          ),
        );
      },
    );
  }

  Widget _bookList(BuildContext context) {
    return ListView.builder(
      key: const ValueKey('list'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: books.length + (isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= books.length) {
          return const LoadingWidget.more();
        }
        final book = books[index];
        return EntranceSlideFade(
          index: index,
          child: BookListTile(
            book: book,
            showCover: true,
            onTap: () => onOpenBook(book),
            // 长按封面：收藏 / 加入书单快捷面板（功能 2）。
            onLongPress: () => showBookQuickActionsSheet(context, book),
          ),
        );
      },
    );
  }

  Widget _bookGrid(BuildContext context) {
    return GridView.builder(
      key: const ValueKey('grid'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        childAspectRatio: 0.60,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: books.length + (isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= books.length) {
          return const LoadingWidget.more();
        }
        final book = books[index];
        return EntranceSlideFade(
          index: index,
          child: BookCard(
            book: book,
            searchResult: true,
            // 搜索结果同屏同 id 重复极罕见（不同 edition id 不同），
            // 可安全开 Hero。
            heroEnabled: true,
            onTap: () => onOpenBook(book),
            // 长按封面：收藏 / 加入书单快捷面板（功能 2）。
            onLongPress: () => showBookQuickActionsSheet(context, book),
          ),
        );
      },
    );
  }
}
