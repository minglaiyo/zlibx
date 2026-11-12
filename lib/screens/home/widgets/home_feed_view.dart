import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/display_book.dart';
import '../../../providers/home_feed_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../../widgets/book_card.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/loading_widget.dart';

/// The recommendation grid.
///
/// Split from the home screen so pagination/refresh updates rebuild only this
/// subtree instead of the header, the tab pages and the navigation bar.
class HomeFeedView extends ConsumerWidget {
  const HomeFeedView({
    super.key,
    required this.scrollController,
    required this.topPadding,
    required this.bottomPadding,
    required this.onRefresh,
    required this.onOpenBook,
  });

  final ScrollController scrollController;

  /// Height of the glass header the grid scrolls under.
  final double topPadding;

  /// Space the last row must reserve for the floating navigation bar.
  final double bottomPadding;

  final Future<void> Function() onRefresh;
  final ValueChanged<DisplayBook> onOpenBook;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only the fields this widget paints are watched: pagination flags are
    // consumed by _FeedFooter, so toggling isLoadingMore no longer rebuilds
    // the whole grid (and its index map).
    final isLoading = ref.watch(homeFeedProvider.select((s) => s.isLoading));
    final books = ref.watch(homeFeedProvider.select((s) => s.books));
    final error = ref.watch(homeFeedProvider.select((s) => s.error));
    final columns = ref.watch(homeGridColumnsProvider);

    if (isLoading && books.isEmpty) {
      return _crossFade(
        _SkeletonFeed(
          key: const ValueKey<String>('skeleton'),
          topPadding: topPadding,
          columns: columns,
        ),
      );
    }
    if (books.isEmpty) {
      return _crossFade(
        _FeedPlaceholder(
          key: const ValueKey<String>('empty'),
          topPadding: topPadding,
          isError: error != null,
          onRefresh: onRefresh,
          onRetry: () => ref.read(homeFeedProvider.notifier).retryInitial(),
        ),
      );
    }

    // Reordering (refresh prepends a page) must reuse the existing elements:
    // without this lookup every shifted child is recreated, which replays the
    // entrance animation and drops image/press state for the whole grid.
    final indexById = <String, int>{
      for (var i = 0; i < books.length; i++) books[i].id: i,
    };

    return _crossFade(
      KeyedSubtree(
        key: const ValueKey<String>('grid'),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const columnSpacing = 16.0;
            const horizontalPadding = 20.0;
            final gridWidth = (constraints.maxWidth - horizontalPadding * 2)
                .clamp(0.0, double.infinity);
            final cardWidth =
                ((gridWidth - columnSpacing * (columns - 1)) / columns).clamp(
                  0.0,
                  double.infinity,
                );

            return RefreshIndicator(
              onRefresh: onRefresh,
              edgeOffset: topPadding,
              displacement: 28,
              child: CustomScrollView(
                controller: scrollController,
                physics: const AlwaysScrollableScrollPhysics(
                  parent: ClampingScrollPhysics(),
                ),
                scrollCacheExtent: const ScrollCacheExtent.pixels(600),
                slivers: <Widget>[
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      topPadding,
                      horizontalPadding,
                      0,
                    ),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: BookCard.compactHeightFor(cardWidth),
                        crossAxisSpacing: columnSpacing,
                        mainAxisSpacing: 12,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final book = books[index];
                          return BookCard(
                            key: ValueKey<String>(book.id),
                            book: book,
                            compact: true,
                            showSourceBadge: true,
                            heroEnabled: true,
                            onTap: () => onOpenBook(book),
                          );
                        },
                        childCount: books.length,
                        findChildIndexCallback: (Key key) {
                          if (key is ValueKey<String>) {
                            return indexById[key.value];
                          }
                          return null;
                        },
                        addAutomaticKeepAlives: false,
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _FeedFooter(bottomPadding: bottomPadding),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _crossFade(Widget child) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: child,
    );
  }
}

class _FeedFooter extends ConsumerWidget {
  const _FeedFooter({required this.bottomPadding});

  final double bottomPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLoadingMore = ref.watch(
      homeFeedProvider.select((s) => s.isLoadingMore),
    );
    final hasMore = ref.watch(homeFeedProvider.select((s) => s.hasMore));
    final error = ref.watch(homeFeedProvider.select((s) => s.loadMoreError));
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    Widget child;
    if (error != null) {
      child = InkWell(
        onTap: () => ref.read(homeFeedProvider.notifier).loadMore(),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.refresh_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                l10n.searchMoreFailed,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              const SizedBox(width: 8),
              Text(
                l10n.retry,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: cs.primary,
                ),
              ),
            ],
          ),
        ),
      );
    } else if (isLoadingMore) {
      child = const LoadingWidget.more();
    } else if (!hasMore) {
      child = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.check_circle_outline_rounded,
            size: 16,
            color: cs.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          const SizedBox(width: 6),
          Text(
            l10n.noMoreBooks,
            style: TextStyle(
              fontSize: 12.5,
              color: cs.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          ),
        ],
      );
    } else {
      child = const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.only(top: 16, bottom: bottomPadding),
      child: SizedBox(height: 52, child: Center(child: child)),
    );
  }
}

class _FeedPlaceholder extends StatelessWidget {
  const _FeedPlaceholder({
    super.key,
    required this.topPadding,
    required this.isError,
    required this.onRefresh,
    required this.onRetry,
  });

  final double topPadding;
  final bool isError;
  final Future<void> Function() onRefresh;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return RefreshIndicator(
      onRefresh: onRefresh,
      edgeOffset: topPadding,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        slivers: <Widget>[
          SliverPadding(
            padding: EdgeInsets.only(top: topPadding + 28),
            sliver: SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: isError ? Icons.cloud_off_rounded : Icons.book_outlined,
                title: isError ? l10n.searchFailed : l10n.noBooksFound,
                message: l10n.shelfRetryHint,
                action: FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(l10n.retry),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Skeleton grid shown while the first page is in flight. One shared ticker
/// sweeps a highlight across all cards, which reads as "loading" without a
/// spinner covering the whole screen.
class _SkeletonFeed extends StatefulWidget {
  const _SkeletonFeed({
    super.key,
    required this.topPadding,
    required this.columns,
  });

  final double topPadding;
  final int columns;

  @override
  State<_SkeletonFeed> createState() => _SkeletonFeedState();
}

class _SkeletonFeedState extends State<_SkeletonFeed>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: 0.58,
    end: 0.92,
  ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _pulse.stop();
      _pulse.value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 16.0;
        const horizontal = 20.0;
        final width = (constraints.maxWidth - horizontal * 2).clamp(
          0.0,
          double.infinity,
        );
        final cardWidth =
            ((width - spacing * (widget.columns - 1)) / widget.columns).clamp(
              0.0,
              double.infinity,
            );
        // One opacity layer for the whole grid. The cards themselves are
        // static; nothing rebuilds per frame beyond this FadeTransition.
        return FadeTransition(
          opacity: _opacity,
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              horizontal,
              widget.topPadding,
              horizontal,
              24,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: widget.columns,
              mainAxisExtent: BookCard.compactHeightFor(cardWidth),
              crossAxisSpacing: spacing,
              mainAxisSpacing: 12,
            ),
            itemCount: math.max(6, widget.columns * 3),
            itemBuilder: (context, index) => const _SkeletonCard(),
          ),
        );
      },
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            cs.surfaceContainerHigh,
            cs.surfaceContainerHighest.withValues(alpha: 0.7),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.auto_stories_rounded,
          size: 22,
          color: cs.onSurfaceVariant.withValues(alpha: 0.16),
        ),
      ),
    );
  }
}
