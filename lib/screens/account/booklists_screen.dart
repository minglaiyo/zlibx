import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/booklist_detail_provider.dart';
import '../../providers/booklists_provider.dart';
import '../../providers/recommended_booklists_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/zlibrary_provider.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_metrics.dart';
import '../../theme/motion.dart';
import '../../utils/app_snack.dart';
import '../../widgets/booklist_card.dart';
import '../../widgets/booklist_quick_actions_sheet.dart';
import '../../widgets/booklist_tile.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/loading_widget.dart';
import '../../widgets/motion/entrance.dart';
import 'widgets/booklist_color_dialog.dart';
import 'widgets/create_booklist_dialog.dart';

/// Booklists: the signed-in user's own booklists and public booklists to
/// discover, with search on both; sort and list/grid view live on
/// discover only — my own lists need neither, and always render as a
/// grid. Tapping a list opens its books. The "my booklists" tab can create a new list
/// (`createBooklist`), edit one, change its color, flip it
/// public/private, favorite it and delete one; adding a book to a list
/// lives on the book detail page (`addBookToBooklist`) and removing a
/// book from a list lives on the detail screen
/// (`BooklistDetailController.removeBook`).
///
/// Loading, paging, cache and the WebView fallback live in
/// [BooklistsController]; this widget only renders its state. The
/// discover list/grid choice is per-screen state (like the search
/// screen's view toggle), not persisted.
class BooklistsScreen extends ConsumerStatefulWidget {
  const BooklistsScreen({super.key});

  @override
  ConsumerState<BooklistsScreen> createState() => _BooklistsScreenState();
}

class _BooklistsScreenState extends ConsumerState<BooklistsScreen> {
  /// 板块顺序(2026-11-19 用户定稿):我的 / 收藏 / 发现。PageView
  /// 三页同序,排字 tab 与页面双向联动;_TypoTabs 必须用同一顺序。
  static const _tabOrder = [
    BooklistTab.mine,
    BooklistTab.favorite,
    BooklistTab.discover,
  ];

  final TextEditingController _searchController = TextEditingController();

  late final PageController _pageController = PageController(
    initialPage: _tabOrder.indexOf(ref.read(booklistsControllerProvider).tab),
  );

  /// 每个 tab 一条独立的竖向滚动(各自记住位置、各自翻页)。
  final Map<BooklistTab, ScrollController> _scrolls = {
    for (final tab in _tabOrder) tab: ScrollController(),
  };

  /// 每个 tab 最近一次非 loading 的整态快照:左右滑动的过程中,
  /// 相邻页先画上次的书单(不白屏),setTab 落地后由实时 state 接管。
  final Map<BooklistTab, BooklistsState> _snapshots = {};

  @override
  void initState() {
    super.initState();
    for (final entry in _scrolls.entries) {
      entry.value.addListener(() => _maybeLoadMore(entry.key, entry.value));
    }
  }

  @override
  void dispose() {
    for (final c in _scrolls.values) {
      c.dispose();
    }
    _pageController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _maybeLoadMore(BooklistTab tab, ScrollController scroll) {
    if (!mounted || !scroll.hasClients) return;
    if (ref.read(booklistsControllerProvider).tab != tab) return;
    if (scroll.position.extentAfter < 300) {
      ref.read(booklistsControllerProvider.notifier).loadMore();
    }
  }

  void _clearSearch() {
    _searchController.clear();
    ref.read(booklistsControllerProvider.notifier).search('');
  }

  /// Ask for a name (and optional description, color, private flag),
  /// create the list on the account, then show it at the top of "my
  /// booklists" without a reload (or refresh in the background when
  /// the answer carried no list).
  Future<void> _createBooklist() async {
    final l10n = AppLocalizations.of(context)!;
    final result =
        await showDialog<
          ({String title, String description, int color, bool isPrivate})
        >(context: context, builder: (context) => const CreateBooklistDialog());
    if (result == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(booklistsControllerProvider.notifier);
    final response = await ref
        .read(zlibraryApiProvider)
        .createBooklist(
          title: result.title,
          description: result.description,
          color: result.color,
          isPrivate: result.isPrivate,
        );
    if (!mounted) return;
    if (response.success) {
      showAppSnackOn(messenger, l10n.booklistCreated);
      // The answer usually carries the created list: put it at the top
      // of the mine page instead of reloading the whole page. When the
      // answer is an empty body (no list to insert), refresh the mine
      // page in the background instead of blocking on it.
      final created = response.data;
      if (created != null) {
        controller.noteBooklistCreated(created);
      } else if (ref.read(booklistsControllerProvider).tab ==
          BooklistTab.mine) {
        controller.refreshMineAfterCreate();
      }
    } else {
      showAppSnackOn(
        messenger,
        l10n.booklistCreateFailed(response.error ?? ''),
      );
    }
  }

  /// Edit one of the user's own lists: prefill the create dialog,
  /// then update the entry in place (or reload when the answer
  /// carried no updated list).
  Future<void> _editBooklist(Booklist list) async {
    final l10n = AppLocalizations.of(context)!;
    final result =
        await showDialog<
          ({String title, String description, int color, bool isPrivate})
        >(
          context: context,
          builder: (context) => CreateBooklistDialog(
            isEdit: true,
            initialTitle: list.name,
            initialDescription: list.description,
            initialColor: list.color,
            initialPrivate: list.isPrivate,
          ),
        );
    if (result == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(booklistsControllerProvider.notifier);
    final response = await controller.editBooklist(
      list,
      title: result.title,
      description: result.description,
      isPrivate: result.isPrivate,
      color: result.color,
    );
    if (!mounted) return;
    if (response.success) {
      showAppSnackOn(messenger, l10n.booklistEdited);
      if (response.data == null) {
        await controller.loadFirst();
      }
    } else {
      showAppSnackOn(messenger, l10n.booklistEditFailed(response.error ?? ''));
    }
  }

  /// Change one of the user's own lists' color via the color dialog.
  Future<void> _changeBooklistColor(Booklist list) async {
    final l10n = AppLocalizations.of(context)!;
    final color = await showDialog<int>(
      context: context,
      builder: (context) => BooklistColorDialog(currentColor: list.color ?? 0),
    );
    if (color == null || color == list.color || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(booklistsControllerProvider.notifier);
    final response = await controller.setBooklistColor(list, color);
    if (!mounted) return;
    showAppSnackOn(
      messenger,
      response.success
          ? l10n.booklistColorChanged
          : l10n.booklistColorFailed(response.error ?? ''),
    );
  }

  /// Flip one of the user's own lists between public and private.
  Future<void> _toggleBooklistPublic(Booklist list) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(booklistsControllerProvider.notifier);
    final response = await controller.toggleBooklistPublic(list);
    if (!mounted) return;
    showAppSnackOn(
      messenger,
      response.success
          ? (list.isPrivate
                ? l10n.booklistMadePublic
                : l10n.booklistMadePrivate)
          : l10n.booklistVisibilityFailed(response.error ?? ''),
    );
  }

  /// Favorite or unfavorite a booklist (either tab).
  Future<void> _toggleBooklistFavorite(Booklist list) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(booklistsControllerProvider.notifier);
    final favorite = !list.isFavorite;
    final response = await controller.setBooklistFavorite(list, favorite);
    if (!mounted) return;
    showAppSnackOn(
      messenger,
      response.success
          ? (favorite ? l10n.booklistFavorited : l10n.booklistUnfavorited)
          : l10n.booklistFavoriteFailed(response.error ?? ''),
    );
  }

  /// Share a booklist's name + URL through the system share sheet.
  Future<void> _shareBooklist(Booklist list) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await SharePlus.instance.share(
        ShareParams(text: '${list.name}\n${list.url}'),
      );
    } catch (_) {
      if (!mounted) return;
      showAppSnack(context, l10n.shareFailed);
    }
  }

  /// One menu action from a card's "…" menu.
  Future<void> _onMenuSelected(Booklist list, BooklistMenuAction action) async {
    switch (action) {
      case BooklistMenuAction.edit:
        await _editBooklist(list);
      case BooklistMenuAction.changeColor:
        await _changeBooklistColor(list);
      case BooklistMenuAction.togglePublic:
        await _toggleBooklistPublic(list);
      case BooklistMenuAction.toggleFavorite:
        await _toggleBooklistFavorite(list);
      case BooklistMenuAction.share:
        await _shareBooklist(list);
      case BooklistMenuAction.delete:
        await _confirmDelete(list);
    }
  }

  /// 封面流里"我的"卡没有可锚定的"…"按钮:长按弹出同动作的底部
  /// 面板(编辑/配色/公开/收藏/分享/删除),执行仍走 [_onMenuSelected]。
  Future<void> _showOwnMenu(Booklist list) async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showModalBottomSheet<BooklistMenuAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                list.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l10n.booklistEdit),
              onTap: () => Navigator.pop(sheetContext, BooklistMenuAction.edit),
            ),
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: Text(l10n.booklistChangeColor),
              onTap: () =>
                  Navigator.pop(sheetContext, BooklistMenuAction.changeColor),
            ),
            ListTile(
              leading: Icon(
                list.isPrivate
                    ? Icons.lock_open_rounded
                    : Icons.lock_outline_rounded,
              ),
              title: Text(
                list.isPrivate
                    ? l10n.booklistMakePublic
                    : l10n.booklistMakePrivate,
              ),
              onTap: () =>
                  Navigator.pop(sheetContext, BooklistMenuAction.togglePublic),
            ),
            ListTile(
              leading: Icon(
                list.isFavorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
              ),
              title: Text(
                list.isFavorite
                    ? l10n.unfavoriteBooklist
                    : l10n.favoriteBooklist,
              ),
              onTap: () => Navigator.pop(
                sheetContext,
                BooklistMenuAction.toggleFavorite,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: Text(l10n.share),
              onTap: () =>
                  Navigator.pop(sheetContext, BooklistMenuAction.share),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: Text(l10n.delete),
              onTap: () =>
                  Navigator.pop(sheetContext, BooklistMenuAction.delete),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    await _onMenuSelected(list, action);
  }

  /// Delete one of the user's own lists: confirm first (destructive),
  /// then the controller's optimistic removal; on failure the list is
  /// restored and the error is shown, on success nothing more is
  /// needed — the controller already removed it and invalidated the
  /// cached page.
  Future<void> _confirmDelete(Booklist list) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.booklistDeleteConfirm,
      message: l10n.booklistDeleteDesc,
      confirmLabel: l10n.delete,
      cancelLabel: l10n.cancel,
    );
    if (!confirmed || !mounted) return;
    unawaited(HapticFeedback.mediumImpact());
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(booklistsControllerProvider.notifier);
    final response = await controller.deleteBooklist(list);
    if (!mounted) return;
    if (response.success) {
      showAppSnackOn(messenger, l10n.booklistDeleted);
    } else {
      showAppSnackOn(
        messenger,
        l10n.booklistDeleteFailed(response.error ?? ''),
      );
    }
  }

  /// Pick a sort order via the single-choice dialog (same idiom as the
  /// domain selector: selected row = filled check in primary + bold
  /// primary title, tap applies + closes).
  Future<void> _pickSortOrder(String currentOrder) async {
    final order = await showDialog<String>(
      context: context,
      builder: (context) => _BooklistSortDialog(currentOrder: currentOrder),
    );
    if (order == null || order == currentOrder) return;
    ref.read(booklistsControllerProvider.notifier).setOrder(order);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(booklistsControllerProvider);
    final recommended = ref.watch(recommendedBooklistsProvider);
    final controller = ref.read(booklistsControllerProvider.notifier);
    // 快照:每次拿到非 loading 的整态都记一份,给相邻页兜底。
    if (state.phase != BooklistsPhase.loading) {
      _snapshots[state.tab] = state;
    }
    final showFab =
        state.tab == BooklistTab.mine &&
        state.phase != BooklistsPhase.loggedOut;

    return Scaffold(
      // 2026-11-19 整体重设计(视觉稿 ①);2026-11-20 五轮定稿:AppBar
      // 整个去掉,玻璃遮罩从状态栏一路包下来(首页同款)——返回键进
      // 玻璃头部,封面流全程从玻璃底下穿过,顶部不再有实底断层。
      // 三个板块是同一屏的三页,左右滑动切换,tab 点击与滑动双向联动。
      floatingActionButton: showFab
          ? FloatingActionButton.extended(
              onPressed: _createBooklist,
              icon: const Icon(Icons.add_rounded),
              label: Text(l10n.createBooklist),
            )
          : null,
      // 2026-11-20:头部改为悬浮毛玻璃遮罩(与首页同款,blurEnabled 门
      // 控)——三个板块的内容从头部底下穿过,滚动时搜索框/tab 后面是
      // 实时模糊的封面流,不再是硬切。
      body: Stack(
        children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _pageController,
              itemCount: _tabOrder.length,
              onPageChanged: (index) {
                final tab = _tabOrder[index];
                if (tab != ref.read(booklistsControllerProvider).tab) {
                  controller.setTab(tab);
                }
              },
              itemBuilder: (context, index) => _page(
                _tabOrder[index],
                l10n,
                state,
                controller,
                recommended,
                topPadding: _feedTopPadding(state),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _glassHeader(l10n, state, controller),
          ),
        ],
      ),
    );
  }

  /// 毛玻璃遮罩头部(与首页完全同款):从状态栏一路包下来,半透明
  /// surface + BackdropFilter 14,blurEnabled(外观设置)关掉时回纯色
  /// 实底。内容 = 返回键 + 搜索框 + 排字 tab(发现/收藏另有排序行)。
  Widget _glassHeader(
    AppLocalizations l10n,
    BooklistsState state,
    BooklistsController controller,
  ) {
    final blurEnabled = ref.watch(blurEnabledProvider);
    final cs = Theme.of(context).colorScheme;
    final topInset = MediaQuery.of(context).padding.top;
    final header = Container(
      decoration: BoxDecoration(
        color: blurEnabled ? cs.surface.withValues(alpha: 0.65) : cs.surface,
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      padding: EdgeInsets.fromLTRB(0, topInset, 0, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: BackButton(),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: SizedBox(
              width: double.infinity,
              child: _searchBar(l10n, controller),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: _TypoTabs(
              active: state.tab,
              labels: {
                BooklistTab.mine: l10n.myBooklists,
                BooklistTab.discover: l10n.discoverBooklists,
                BooklistTab.favorite: l10n.booklistsFavoriteTab,
              },
              onSelect: (tab) {
                controller.setTab(tab);
                _pageController.animateToPage(
                  _tabOrder.indexOf(tab),
                  duration: AppMotion.medium,
                  curve: MotionCurves.enter,
                );
              },
            ),
          ),
          // 排序只在发现/收藏出现;视图切换被封面流取代,删。
          if (state.tab != BooklistTab.mine) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _pickSortOrder(state.order),
                  icon: const Icon(Icons.swap_vert_rounded, size: 18),
                  label: Text(_sortLabel(l10n, state.order)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    if (!blurEnabled) return header;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: header,
      ),
    );
  }

  /// 信息流内容的顶部预留 = 状态栏 + 玻璃头部高度。头部各行内容固定,
  /// 按行高累加;排序行只在发现/收藏出现,PageView 页各自取值。
  double _feedTopPadding(BooklistsState state) {
    final inset = MediaQuery.of(context).padding.top;
    final base =
        inset +
        8 +
        48 + // 返回键行
        4 +
        44 + // 搜索框
        12 +
        36 + // tab 行
        10 +
        8;
    return state.tab == BooklistTab.mine ? base : base + 54; // 排序行
  }

  /// The current sort order's label for the sort button.
  String _sortLabel(AppLocalizations l10n, String order) {
    return switch (order) {
      'date_created' => l10n.booklistSortNewest,
      'date_updated' => l10n.booklistSortUpdated,
      _ => l10n.booklistSortPopular,
    };
  }

  // Capsule search field + soft shadow, matching the library page.
  Widget _searchBar(AppLocalizations l10n, BooklistsController controller) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        boxShadow: AppShadows.elevated(Theme.of(context).brightness),
      ),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _searchController,
        builder: (context, value, _) => TextField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          onSubmitted: controller.search,
          decoration: InputDecoration(
            hintText: l10n.searchBooklists,
            // 用户定稿(2026-11-20):占位文字靠左,放大镜在最右;输入
            // 非空时清空钮并排出现在放大镜左侧。
            prefixIcon: null,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 10,
            ),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (value.text.isNotEmpty)
                  IconButton(
                    tooltip: l10n.clear,
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: _clearSearch,
                  ),
                const Icon(Icons.search_rounded),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 一页 = 一个 tab 的内容。当前页吃 controller 的实时 state;
  /// 相邻页吃 [_snapshots] 的旧数据,滑动过程里不白屏。[topPadding]
  /// 给毛玻璃头部让位(2026-11-20 悬浮头部改版)。
  Widget _page(
    BooklistTab tab,
    AppLocalizations l10n,
    BooklistsState live,
    BooklistsController controller,
    RecommendedBooklistsState recommended, {
    double topPadding = 0,
  }) {
    final isLive = tab == live.tab;
    final state = isLive ? live : _snapshots[tab];

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
              onPressed: () => AppRoutes.openLogin(context),
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
                    onPressed: controller.loadFirst,
                    child: Text(l10n.retry),
                  )
                : null,
          ),
        ],
      );
    } else {
      content = ListView(
        controller: _scrolls[tab],
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(top: topPadding),
        children: [
          if (tab == BooklistTab.discover && recommended.lists.isNotEmpty)
            _RecommendedSection(l10n: l10n, lists: recommended.lists),
          if (state.lists.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 80),
              child: EmptyState(
                icon: Icons.collections_bookmark_outlined,
                title: l10n.noBooklists,
              ),
            )
          else
            BooklistMasonryGrid(
              lists: state.lists,
              showFavoriteBadge: tab != BooklistTab.mine,
              onOpen: (list) => AppRoutes.openBooklistDetail(
                context,
                BooklistDetailArgs(
                  booklist: list,
                  canEdit: tab == BooklistTab.mine,
                ),
              ),
              onLongPress: (list) {
                if (tab == BooklistTab.mine) {
                  _showOwnMenu(list);
                } else {
                  showBooklistQuickActionsSheet(context, list);
                }
              },
            ),
          if (state.isLoadingMore)
            const Padding(
              padding: EdgeInsets.all(12),
              child: LoadingWidget.more(),
            ),
          // Room for the floating action button.
          const SizedBox(height: 96),
        ],
      );
    }
    // 下拉刷新只对当前页有实义;相邻页给空 future,避免把上一个
    // tab 的刷新误当成本页数据。
    return RefreshIndicator(
      onRefresh: isLive ? controller.refresh : () async {},
      child: content,
    );
  }
}

/// Recommended booklists above the discover list: a section header and
/// a horizontal row of grid tiles.
class _RecommendedSection extends StatelessWidget {
  final AppLocalizations l10n;
  final List<Booklist> lists;

  const _RecommendedSection({required this.l10n, required this.lists});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            l10n.recommendedBooklists,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        _CoverFlow(
          lists: lists,
          onOpen: (list) => AppRoutes.openBooklistDetail(
            context,
            BooklistDetailArgs(booklist: list),
          ),
          onLongPress: (list) => showBooklistQuickActionsSheet(context, list),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// 推荐区专用横向封面条(主体已改上下两列,见 BooklistMasonryGrid):
/// 158×224 大卡横向惯性滑动、错峰入场;不分页。
class _CoverFlow extends StatelessWidget {
  final List<Booklist> lists;
  final ValueChanged<Booklist> onOpen;
  final ValueChanged<Booklist> onLongPress;

  const _CoverFlow({
    required this.lists,
    required this.onOpen,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 252,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        itemCount: lists.length,
        itemBuilder: (context, index) {
          final list = lists[index];
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: MotionEntrance(
              index: index,
              child: BooklistCoverCard(
                list: list,
                width: 158,
                height: 224,
                onTap: () => onOpen(list),
                onLongPress: () => onLongPress(list),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 排字式 tab:选中项 22px 加粗 + 短墨条(AnimatedContainer 展开),
/// 未选中回小字灰;取代系统胶囊分段器(视觉稿 ①)。
class _TypoTabs extends StatelessWidget {
  final BooklistTab active;
  final Map<BooklistTab, String> labels;
  final ValueChanged<BooklistTab> onSelect;

  const _TypoTabs({
    required this.active,
    required this.labels,
    required this.onSelect,
  });

  // 与 _tabOrder 同序:我的 / 收藏 / 发现。
  static const _order = [
    BooklistTab.mine,
    BooklistTab.favorite,
    BooklistTab.discover,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 排字号 + 英文长标签可能超过屏宽:横向可滚,滚动条不显。
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _order.length; i++) ...[
            if (i > 0) const SizedBox(width: 18),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(_order[i]),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedDefaultTextStyle(
                    duration: AppMotion.fast,
                    style: _order[i] == active
                        ? theme.textTheme.titleLarge!.copyWith(
                            fontWeight: FontWeight.w800,
                          )
                        : theme.textTheme.bodyMedium!.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                    child: Text(labels[_order[i]]!),
                  ),
                  const SizedBox(height: 5),
                  AnimatedContainer(
                    duration: AppMotion.fast,
                    curve: Curves.easeOutCubic,
                    height: 3,
                    width: _order[i] == active ? 22 : 0,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Single-choice sort dialog, same idiom as the domain selector:
/// selected row = filled check in primary + bold primary title, tap
/// applies + closes. Pops the picked `order` value, or null when
/// cancelled.
class _BooklistSortDialog extends StatelessWidget {
  final String currentOrder;

  const _BooklistSortDialog({required this.currentOrder});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final options = <(String, String)>[
      ('popular', l10n.booklistSortPopular),
      ('date_created', l10n.booklistSortNewest),
      ('date_updated', l10n.booklistSortUpdated),
    ];
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      title: Text(l10n.booklistSort, style: const TextStyle(fontSize: 18)),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: options.length,
          itemBuilder: (context, index) {
            final (value, label) = options[index];
            final selected = value == currentOrder;
            return ListTile(
              dense: true,
              title: Text(
                label,
                style: selected
                    ? TextStyle(color: cs.primary, fontWeight: FontWeight.w700)
                    : null,
              ),
              trailing: Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
              onTap: () => Navigator.of(context).pop(value),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }
}
