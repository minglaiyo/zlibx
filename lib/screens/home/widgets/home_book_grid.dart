import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/display_book.dart';
import '../../../providers/settings_provider.dart';
import '../../../routes/app_routes.dart';
import '../../../theme/app_layout.dart';
import '../../../widgets/book_quick_actions_sheet.dart';
import '../../../widgets/book_card.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/motion/motion.dart';
import '../../../widgets/loading_widget.dart';

/// The recommendation grid plus its empty / loading / error states.
///
/// 下拉刷新在所有状态下都要能用，所以 RefreshIndicator 只包在最外层，
/// 四档内容各给一个可越界滚动的子组件（网格自带，空态 / 加载 / 错误
/// 用 ListView + AlwaysScrollableScrollPhysics）。
///
/// 这不是多余的讲究：错误态和空态在个性化推荐接口失败 / 返回空列表时
/// 就会碰到（2026-11-15 去掉热门兜底之后，这两档从"几乎到不了"变成
/// 首页的常态之一），而 RefreshIndicator 的手势要靠子组件的越界滚动
/// 触发——一个既不能滚动、又没有下拉层的 Padding，用户怎么拉都没反应，
/// 又没有重试按钮，等于把首页关死在错误页上。
class HomeBookGrid extends ConsumerWidget {
  const HomeBookGrid({
    super.key,
    required this.booksAsync,
    required this.topPadding,
    required this.scrollController,
    required this.onRefresh,
  });

  final AsyncValue<List<DisplayBook>> booksAsync;
  final double topPadding;
  final ScrollController scrollController;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 外观设置里的"书籍网格自适应列数"（默认关）。关掉时首页走 1.6.0
    // 之前的老规则：左右留白固定 20、列数按卡片最大宽度 220 估——手机上
    // 就是 2 列，逐像素和旧版一致。
    final adaptive = ref.watch(adaptiveGridProvider);
    // topPadding reserves the floating glass header's height inside the
    // scrollable, so the grid scrolls underneath the header (blurred)
    // instead of starting below it.
    return RefreshIndicator(
      onRefresh: onRefresh,
      // The spinner must appear below the floating glass header,
      // not behind it (the header paints on top of the grid).
      edgeOffset: topPadding,
      child: booksAsync.when(
        data: (books) {
          if (books.isEmpty) {
            return _StatePane(
              topPadding: topPadding,
              child: EmptyState(
                icon: Icons.book_outlined,
                title: AppLocalizations.of(context)!.noBooksFound,
              ),
            );
          }

          final itemCount = books.length;

          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;

              // 列数和左右留白都问 AppLayout，传的都是网格盒子自身的宽度
              // （留白在公式里扣）。自适应开 = 手机 3 列、平板按宽度加列、
              // 留白随断点走；关 = 老规则，留白固定 20、列数按卡片最大宽度
              // 220 估，与 1.6.0 之前的首页逐像素一致。
              const columnSpacing = AppLayout.gridSpacing;
              final gutter = adaptive
                  ? AppLayout.pageGutter(width)
                  : AppLayout.legacyGutter;
              final gridWidth = (width - gutter * 2).clamp(
                0.0,
                double.infinity,
              );
              final columns = adaptive
                  ? AppLayout.gridColumns(width)
                  : AppLayout.legacyGridColumns(gridWidth);
              final cardWidth =
                  ((gridWidth - columnSpacing * (columns - 1)) / columns).clamp(
                    0.0,
                    double.infinity,
                  );

              return GridView.builder(
                controller: scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(gutter, topPadding, gutter, 96),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisExtent: BookCard.compactHeightFor(cardWidth),
                  crossAxisSpacing: columnSpacing,
                  mainAxisSpacing: 12,
                ),
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  final book = books[index];
                  return MotionEntrance(
                    index: index,
                    child: BookCard(
                      book: book,
                      compact: true,
                      showSourceBadge: true,
                      onTap: () {
                        AppRoutes.openBookDetailForDisplayBook(context, book);
                      },
                      // 长按封面：收藏 / 加入书单快捷面板（功能 2 推广）。
                      // 非外部源书（无 z 站收藏体系）面板自身不弹。
                      onLongPress: () =>
                          showBookQuickActionsSheet(context, book),
                    ),
                  );
                },
              );
            },
          );
        },
        loading: () => _StatePane(
          topPadding: topPadding,
          child: LoadingWidget(
            message: AppLocalizations.of(context)!.loadingTrendingBooks,
          ),
        ),
        error: (error, stack) => _StatePane(
          topPadding: topPadding,
          child: EmptyState(
            icon: Icons.error_outline,
            title: AppLocalizations.of(context)!.couldNotLoadBooks,
            message: AppLocalizations.of(context)!.checkYourConnection,
            // 显式重试入口：除了下拉，点按钮也要能重新拉一次——与
            // 热门 / 最新上架两页同构（那两页错误态就有这个按钮）。
            action: TextButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: Text(AppLocalizations.of(context)!.retry),
            ),
          ),
        ),
      ),
    );
  }
}

/// 空态 / 加载 / 错误三档的外壳：一个可越界滚动的 ListView，让外层
/// RefreshIndicator 在这些状态下也收得到下拉手势（网格分支自带
/// GridView，不走这里）。内容顶部留出悬浮头部的空间。
class _StatePane extends StatelessWidget {
  const _StatePane({required this.topPadding, required this.child});

  final double topPadding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(20, topPadding + 40, 20, 40),
      children: [child],
    );
  }
}
