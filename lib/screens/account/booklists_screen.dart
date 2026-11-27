import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/booklist_detail_provider.dart';
import '../../providers/booklists_provider.dart';
import '../../providers/recommended_booklists_provider.dart';
import '../../providers/zlibrary_provider.dart';
import '../../routes/app_routes.dart';
import '../../theme/motion.dart';
import '../../utils/app_snack.dart';
import '../../utils/diagnostics.dart';
import '../../widgets/booklist_card.dart';
import '../../widgets/booklist_quick_actions_sheet.dart';
import '../../widgets/confirm_dialog.dart';
import 'widgets/booklist_color_dialog.dart';
import 'widgets/booklist_own_menu.dart';
import 'widgets/booklist_sort_dialog.dart';
import 'widgets/booklists_glass_header.dart';
import 'widgets/booklists_tab_page.dart';
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
  /// 三页同序,排字 tab 与页面双向联动;BooklistsTypoTabs 必须用同一顺序。
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
    } catch (error) {
      logIgnored('booklist_share', error);
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
    final action = await showBooklistOwnMenuSheet(context, list);
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
      builder: (context) => BooklistSortDialog(currentOrder: currentOrder),
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
              itemBuilder: (context, index) {
                final tab = _tabOrder[index];
                final isLive = tab == state.tab;
                return BooklistsTabPage(
                  tab: tab,
                  state: isLive ? state : _snapshots[tab],
                  isLive: isLive,
                  l10n: l10n,
                  recommendedLists: recommended.lists,
                  topPadding: _feedTopPaddingFor(tab),
                  scrollController: _scrolls[tab]!,
                  onRefresh: isLive ? controller.refresh : () async {},
                  onRetry: controller.loadFirst,
                  onLogin: () => AppRoutes.openLogin(context),
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
                );
              },
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: BooklistsGlassHeader(
              l10n: l10n,
              tab: state.tab,
              order: state.order,
              searchController: _searchController,
              onSearchSubmitted: controller.search,
              onClearSearch: _clearSearch,
              onSelectTab: (tab) {
                controller.setTab(tab);
                _pageController.animateToPage(
                  _tabOrder.indexOf(tab),
                  duration: AppMotion.medium,
                  curve: MotionCurves.enter,
                );
              },
              onPickSort: () => _pickSortOrder(state.order),
            ),
          ),
        ],
      ),
    );
  }

  /// 信息流内容的顶部预留 = 状态栏 + 玻璃头部高度。头部各行内容固定,
  /// 按行高累加;排序行只在发现/收藏出现,PageView 页各自取值。
  /// PageView 的每个页面用自己的 tab 取值（审查 v2 P2-9）：此前取
  /// 当前 live tab 的值，相邻页滑动期间少让位 54px，内容短暂钻进头
  /// 部。各行高度是固定值（返回键/搜索框都是定高），这里保持常量累
  /// 加，不做布局期实测。
  double _feedTopPaddingFor(BooklistTab tab) {
    final inset = MediaQuery.paddingOf(context).top;
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
    return tab == BooklistTab.mine ? base : base + 54; // 排序行
  }
