import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/display_book.dart';
import '../../../providers/settings_provider.dart';
import '../../../routes/app_routes.dart';
import '../../../utils/cover_cache.dart';
import '../../../widgets/book_card.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/entrance.dart';
import '../../../widgets/loading_widget.dart';

/// The recommendation grid plus its empty / loading / error states.
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
    // 外观设置里的"推荐页四列布局"：开 = 固定 4 列；关（默认）= 按
    // 卡片最大宽度自适应列数。
    final fourColumns = ref.watch(homeGridFourColumnsProvider);
    // topPadding reserves the floating glass header's height inside the
    // scrollable, so the grid scrolls underneath the header (blurred)
    // instead of starting below it.
    return booksAsync.when(
      data: (books) {
        if (books.isEmpty) {
          return Padding(
            padding: EdgeInsets.fromLTRB(40, topPadding + 40, 40, 40),
            child: EmptyState(
              icon: Icons.book_outlined,
              title: AppLocalizations.of(context)!.noBooksFound,
            ),
          );
        }

        final itemCount = books.length;

        return LayoutBuilder(
          builder: (context, constraints) {
            const maxCardWidth = 220.0;
            const columnSpacing = 16.0;
            const horizontalPadding = 20.0;
            final gridWidth = (constraints.maxWidth - horizontalPadding * 2)
                .clamp(0.0, double.infinity);
            final columnCount = fourColumns
                ? 4
                : (gridWidth / (maxCardWidth + columnSpacing))
                    .ceil()
                    .clamp(1, double.infinity);
            final cardWidth =
                ((gridWidth - columnSpacing * (columnCount - 1)) / columnCount)
                    .clamp(0.0, double.infinity);

            // 四列模式 = 官方 App 风格的纯封面密排网格：无边框卡片、
            // 无徽标、封面铺满、小间距。
            if (fourColumns) {
              final cellWidth = ((gridWidth - 8 * 3) / 4)
                  .clamp(0.0, double.infinity);
              return RefreshIndicator(
                onRefresh: onRefresh,
                edgeOffset: topPadding,
                child: GridView.builder(
                  controller: scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(12, topPadding, 12, 96),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 2 / 3,
                  ),
                  itemCount: itemCount,
                  itemBuilder: (context, index) {
                    final book = books[index];
                    return _CoverTile(
                      book: book,
                      cellWidth: cellWidth,
                      onTap: () {
                        AppRoutes.openBookDetailForDisplayBook(context, book);
                      },
                    );
                  },
                ),
              );
            }

            return RefreshIndicator(
              onRefresh: onRefresh,
              // The spinner must appear below the floating glass header,
              // not behind it (the header paints on top of the grid).
              edgeOffset: topPadding,
              child: GridView.builder(
                controller: scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(20, topPadding, 20, 96),
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: maxCardWidth,
                  mainAxisExtent: BookCard.compactHeightFor(cardWidth),
                  crossAxisSpacing: columnSpacing,
                  mainAxisSpacing: 12,
                ),
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  final book = books[index];
                  return EntranceSlideFade(
                    index: index,
                    child: BookCard(
                      book: book,
                      compact: true,
                      showSourceBadge: true,
                      onTap: () {
                        AppRoutes.openBookDetailForDisplayBook(context, book);
                      },
                    ),
                  );
                },
              ),
            );
          },
        );
      },
      loading: () => Padding(
        padding: EdgeInsets.only(top: topPadding + 40, bottom: 40),
        child: LoadingWidget(
          message: AppLocalizations.of(context)!.loadingTrendingBooks,
        ),
      ),
      error: (error, stack) => Padding(
        padding: EdgeInsets.fromLTRB(20, topPadding + 20, 20, 20),
        child: EmptyState(
          icon: Icons.error_outline,
          title: AppLocalizations.of(context)!.couldNotLoadBooks,
          message: AppLocalizations.of(context)!.checkYourConnection,
        ),
      ),
    );
  }
}

/// 四列模式的一个纯封面格（官方 App 风格）：无边框、无徽标、封面
/// 铺满 2:3 格子，点按进详情。封面按格宽解码（[coverCacheWidth]），
/// 长列表滑动不掉帧。
class _CoverTile extends StatelessWidget {
  const _CoverTile({
    required this.book,
    required this.cellWidth,
    required this.onTap,
  });

  final DisplayBook book;
  final double cellWidth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 要图与解码同宽：列表给的是 covers100 缩略图，按格宽直接解码
    // 会糊；按解码宽度要高清版（coverUrlAtWidth）。
    final cacheWidth = coverCacheWidth(cellWidth, context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: CachedNetworkImage(
            imageUrl: coverUrlAtWidth(book.cover ?? '', cacheWidth),
            fit: BoxFit.cover,
            memCacheWidth: cacheWidth,
            placeholder: (context, url) =>
                ColoredBox(color: cs.surfaceContainerHighest),
            errorWidget: (context, url, error) => ColoredBox(
              color: cs.surfaceContainerHighest,
              child: Icon(Icons.menu_book_outlined, color: cs.outline),
            ),
          ),
        ),
      ),
    );
  }
}
