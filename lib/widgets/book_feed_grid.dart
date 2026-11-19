import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/generated/app_localizations.dart';
import '../providers/feed_controller.dart';
import '../providers/settings_provider.dart';
import '../routes/app_routes.dart';
import '../theme/app_layout.dart';
import '../utils/error_text.dart';
import 'book_card.dart';
import 'book_quick_actions_sheet.dart';
import 'empty_state.dart';
import 'motion/motion.dart';

/// 热门 / 最新两页共享的信息流网格（2026-11-20 改版）。
///
/// 与首页 [HomeBookGrid] 同一套 [FeedState] 语义：四档状态 + 滚到离底
/// 600px 触发 [onLoadMore] 追加下一页，尾部按 hasMore 画加载行；下拉
/// 刷新在所有状态下可用（RefreshIndicator 包外层，四档各给可越界滚动
/// 的子组件）。卡片是纯封面款（coverOnly，封面角评分），与两页改版前
/// 的观感一致。
class BookFeedGrid extends ConsumerWidget {
  const BookFeedGrid({
    super.key,
    required this.feed,
    required this.onRefresh,
    required this.onLoadMore,
    required this.emptyState,
  });

  final FeedState feed;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;

  /// 各页自己的空态（图标 / 标题 / 文案随页）。
  final Widget emptyState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adaptive = ref.watch(adaptiveGridProvider);
    final books = feed.books;

    Widget body;
    if (feed.error != null && books.isEmpty) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.2),
          EmptyState(
            icon: Icons.error_outline,
            title: AppLocalizations.of(context)!.error,
            message: friendlyErrorText(feed.error!, AppLocalizations.of(context)!),
          ),
          Center(
            child: TextButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: Text(AppLocalizations.of(context)!.retry),
            ),
          ),
        ],
      );
    } else if (books.isEmpty && feed.isLoading) {
      // 加载档也必须能下拉：RefreshIndicator 的手势靠子组件越界滚动
      // 触发，所以这里给一个可滚的 ListView 外壳。接口慢或这条线被墙
      // 时页面就停在这一档，只能下拉刷新，等数据到了再出内容。
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.2),
        ],
      );
    } else if (books.isEmpty) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.2),
          emptyState,
        ],
      );
    } else {
      final itemCount = books.length + (feed.hasMore ? 1 : 0);
      body = NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          // pixels >= 0：顶部下拉刷新是负向越界，别让它误触上滑加载
          // （短列表 maxScrollExtent=0 时顶部任何拖动都会进这个分支）。
          // maxScrollExtent > 0：列表真的可滚才谈得上"接近底部"——
          // 短列表（max=0）连拖拽回弹落回 0 的那一帧都会进这个分支，
          // 会把 loadMore 连环误触。
          if (feed.hasMore &&
              notification.metrics.maxScrollExtent > 0 &&
              notification.metrics.pixels >
                  notification.metrics.maxScrollExtent - 600) {
            onLoadMore();
          }
          return false;
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final gutter = adaptive ? AppLayout.pageGutter(width) : 16.0;
            return GridView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 24),
              // 自适应档：列数 / 留白 / 间距走 BookCard 那一个工厂，
              // 和首页同一套规则（手机上就是 3 列），格高只给封面
              // （coverOnly），信息区不再占高度。关掉时保持本页原来
              // 的固定委托：两列、间距 12，比例换成纯封面的 0.7。
              gridDelegate: adaptive
                  ? BookCard.adaptiveGridDelegate(
                      context,
                      width,
                      coverOnly: true,
                    )
                  : const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      childAspectRatio: BookCard.coverAspectRatio,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
              itemCount: itemCount,
              itemBuilder: (context, index) {
                if (index >= books.length) {
                  // 信息流尾部：加载行（hasMore 才占格）。
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: feed.isLoadingMore
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.4),
                            )
                          : const SizedBox.shrink(),
                    ),
                  );
                }
                final book = books[index];
                return MotionEntrance(
                  index: index,
                  child: BookCard(
                    book: book,
                    // 与首页推荐同款观感：只有封面和封面上的评分，
                    // 书名 / 作者 / 格式 / 大小那几行不再占格子。
                    coverOnly: true,
                    // 长按封面：收藏 / 加入书单快捷面板（与最新上架一致）。
                    onLongPress: () => showBookQuickActionsSheet(context, book),
                    onTap: () {
                      AppRoutes.openBookDetailForDisplayBook(context, book);
                    },
                  ),
                );
              },
            );
          },
        ),
      );
    }

    return RefreshIndicator(onRefresh: onRefresh, child: body);
  }
}
