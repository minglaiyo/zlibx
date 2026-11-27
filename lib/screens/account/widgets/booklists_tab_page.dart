/// One tab page of the booklists screen (P1-4 split of
/// booklists_screen.dart): the loading skeleton, the logged-out and
/// error states, and the ready list (recommended section on discover,
/// empty state, masonry grid, load-more indicator).
///
/// The live page eats the controller's realtime state; neighbouring
/// pages eat the screen's snapshots of old data, so swiping never
/// whites out. [state] is null before the first snapshot exists
/// (loading).
library;

import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/booklists_provider.dart';
import '../../../widgets/booklist_card.dart';
import '../../../widgets/booklist_tile.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/loading_widget.dart';
import 'recommended_booklists_section.dart';

class BooklistsTabPage extends StatelessWidget {
  const BooklistsTabPage({
    super.key,
    required this.tab,
    required this.state,
    required this.isLive,
    required this.l10n,
    required this.recommendedLists,
    required this.topPadding,
    required this.scrollController,
    required this.onRefresh,
    required this.onRetry,
    required this.onLogin,
    required this.onOpen,
    required this.onLongPress,
  });

  final BooklistTab tab;
  final BooklistsState? state;
  final bool isLive;
  final AppLocalizations l10n;
  final List<Booklist> recommendedLists;

  /// Top padding reserving room for the floating glass header.
  final double topPadding;
  final ScrollController scrollController;

  /// Pull-to-refresh: the live page refreshes, neighbours no-op.
  final Future<void> Function() onRefresh;

  /// Error-state retry (live page only) and logged-out login button.
  final VoidCallback onRetry;
  final VoidCallback onLogin;

  /// Open a list (`canEdit` is decided by the screen) and long-press
  /// a list (own menu on mine, quick actions elsewhere).
  final ValueChanged<Booklist> onOpen;
  final ValueChanged<Booklist> onLongPress;

  @override
  Widget build(BuildContext context) {
    final state = this.state;

    Widget content;
    if (state == null || state.phase == BooklistsPhase.loading) {
      content = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(top: topPadding),
        children: const [BooklistSkeletonList()],
      );
    } else if (state.phase == BooklistsPhase.loggedOut) {
      content = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: topPadding + 96),
          EmptyState(
            icon: Icons.login_rounded,
            title: l10n.loginToViewBooklists,
            action: FilledButton(
              onPressed: onLogin,
              child: Text(l10n.login),
            ),
          ),
        ],
      );
    } else if (state.phase == BooklistsPhase.error) {
      content = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: topPadding + 96),
          EmptyState(
            icon: Icons.error_outline,
            title: l10n.error,
            message: state.error,
            action: isLive
                ? FilledButton(
                    onPressed: onRetry,
                    child: Text(l10n.retry),
                  )
                : null,
          ),
        ],
      );
    } else {
      // P3-2: the ready list is a CustomScrollView — the recommended
      // section is its own sliver and the masonry grid builds rows
      // lazily ([BooklistMasonrySliverList]) instead of all cards up
      // front in two Columns. Loading / logged-out / error states
      // stay ListViews: they render a single screen, nothing to lazy-load.
      // The same [scrollController] drives pagination, and
      // RefreshIndicator works over a CustomScrollView as before.
      content = CustomScrollView(
        controller: scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: SizedBox(height: topPadding)),
          if (tab == BooklistTab.discover && recommendedLists.isNotEmpty)
            SliverToBoxAdapter(
              child: RecommendedBooklistsSection(
                l10n: l10n,
                lists: recommendedLists,
              ),
            ),
          if (state.lists.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 80),
                child: EmptyState(
                  icon: Icons.collections_bookmark_outlined,
                  title: l10n.noBooklists,
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              sliver: BooklistMasonrySliverList(
                lists: state.lists,
                showFavoriteBadge: tab != BooklistTab.mine,
                onOpen: onOpen,
                onLongPress: onLongPress,
              ),
            ),
          if (state.isLoadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: LoadingWidget.more(),
              ),
            ),
          // Room for the floating action button.
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      );
    }
    // 下拉刷新只对当前页有实义;相邻页给空 future,避免把上一个
    // tab 的刷新误当成本页数据。
    return RefreshIndicator(onRefresh: onRefresh, child: content);
  }
}
