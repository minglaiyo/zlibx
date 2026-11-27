import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/booklist_detail_provider.dart';
import '../../routes/app_routes.dart';
import '../../utils/app_snack.dart';
import '../../widgets/booklist_quick_actions_sheet.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/loading_widget.dart';
import 'widgets/booklist_detail_actions.dart';
import 'widgets/booklist_detail_grid.dart';
import 'widgets/booklist_detail_hero.dart';
import 'widgets/booklist_detail_states.dart';

// Existing callers (main.dart routes, the profile page) import the args
// class from this screen's library.
export '../../providers/booklist_detail_provider.dart' show BooklistDetailArgs;
// BooklistShelfTile moved to widgets/booklist_detail_grid.dart (P1-4);
// re-exported so the existing widget test keeps importing it from here.
export 'widgets/booklist_detail_grid.dart' show BooklistShelfTile;

/// 书单详情页(2026-11-19 整体重设计,视觉稿 ③):
///
/// * 视差大字头:书单封面高斯模糊铺底 + 暗罩,前三本书的封面扇形
///   堆叠在中央,书名白色大字压在下缘;滚动时背景层以 0.35 系数
///   上移(视差),收起过程中书名渐显进 AppBar 标题;
/// * 白色圆角 sheet 从头部下探出:作者 chip(头像·名,点击进主页)
///   + 玻璃胶囊行(收藏 toggle / 分享——官方页头部的两个动作) +
///   书单内搜索与排序行;
/// * 书籍区:首页同款自适应多列封面网格,逐张错峰淡入;
/// * 自己的单(canEdit):长按书卡弹"批注/移出"面板;
/// * 搜索与排序都是**客户端**的(只作用于已加载页,标题即说明
///   ——不冒充服务端全量搜索);官方的"评论"tab 需要书单评论接口,
///   vendor 暂无对应端点,不做假入口。
///
/// 加载、分页、缓存与 WebView 兜底仍全部在 [BooklistDetailController];
/// 收藏态是本地镜像([_favorite]),写入成功后翻转。
///
/// P1-4 拆分:AppBar 与视差头图见 [BooklistDetailHero]、书架网格见
/// [BooklistDetailBookGrid]、空态与错误态见
/// `widgets/booklist_detail_states.dart`、底部操作见
/// `widgets/booklist_detail_actions.dart`。本文件只留状态与编排。
class BooklistDetailScreen extends ConsumerStatefulWidget {
  final BooklistDetailArgs args;

  const BooklistDetailScreen({super.key, required this.args});

  @override
  ConsumerState<BooklistDetailScreen> createState() =>
      _BooklistDetailScreenState();
}

class _BooklistDetailScreenState extends ConsumerState<BooklistDetailScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  late final _provider = booklistDetailControllerProvider(widget.args);

  late bool _favorite = widget.args.booklist.isFavorite;

  /// 客户端过滤词与排序方向(从新到旧为默认,和官方页一致)。
  String _query = '';
  bool _newestFirst = true;

  /// 视差位移:滚动像素缓存,头图背景层按 0.35 反向跟随。
  /// ValueNotifier（审查 v2 P1-3）：滚动每 tick 只重建头图视差层，
  /// 不再整屏 setState。
  final ValueNotifier<double> _pixels = ValueNotifier(0);

  // _visibleBooks 的记忆化缓存：滚动无关的重建不再重跑全量过滤+排序。
  List<Book>? _visibleCache;
  List<Book>? _visibleCacheBooks;
  String? _visibleCacheQuery;
  bool? _visibleCacheSort;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _pixels.dispose();
    super.dispose();
  }

  void _onScroll() {
    _pixels.value = _scrollController.position.pixels;
    // 按需加载（书单思路）：不再滑到底自动拉下一页，超过一页的量
    // 由底部的“加载更多”按钮拉。自动拉会在墙（DiamWall）上反复
    // 撞，按钮让用户自己决定什么时候拉。
  }

  Future<void> _toggleFavorite() async {
    final want = !_favorite;
    final ok = await runBooklistFavorite(
      context,
      widget.args.booklist,
      wantFavorite: want,
    );
    if (ok && mounted) setState(() => _favorite = want);
  }

  /// #101：导出书单文本清单。书是分页加载的，先把没拉的页拉完
  /// （上限 200 页，和书单分页上限一致），清单才完整；拉的时候转
  /// 个圈（已全量时直接分享，不转圈）。空书单不分享，给个提示。
  Future<void> _exportBookList() async {
    final controller = ref.read(_provider.notifier);
    var dialogShown = false;
    try {
      if (ref.read(_provider).hasMore) {
        if (!mounted) return;
        dialogShown = true;
        unawaited(
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => const Center(child: CircularProgressIndicator()),
          ),
        );
        var guard = 0;
        while (ref.read(_provider).hasMore && guard < 200) {
          guard++;
          await controller.loadMore();
          if (!mounted) return;
          // 单页失败就停：导已加载的部分，别把同一页重试 200 次。
          if (ref.read(_provider).loadMoreError != null) break;
        }
      }
    } finally {
      // 页面还在才关转圈；页面已关时转圈随路由一起走了，不用管。
      if (dialogShown && mounted) Navigator.pop(context);
    }
    if (!mounted) return;
    final books = ref.read(_provider).books;
    if (books.isEmpty) {
      showAppSnack(
        context,
        AppLocalizations.of(context)!.noBooklistBooks,
      );
      return;
    }
    await runBooklistShare(
      context,
      widget.args.booklist,
      books: [
        for (final book in books)
          (
            title: book.title,
            author: book.author,
            year: book.year?.toString(),
          ),
      ],
    );
  }

  /// Remove one book from this (own) list: confirm first, then the
  /// controller's optimistic removal; on failure the book is restored
  /// and the error is shown.
  Future<void> _confirmRemove(Book book) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.booklistRemoveBookConfirm,
      message: book.title,
      confirmLabel: l10n.remove,
      cancelLabel: l10n.cancel,
    );
    if (!confirmed || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final response = await ref.read(_provider.notifier).removeBook(book);
    if (!mounted) return;
    if (response.success) {
      showAppSnackOn(messenger, l10n.booklistBookRemoved);
    } else {
      showAppSnackOn(
        messenger,
        l10n.booklistRemoveBookFailed(response.error ?? ''),
      );
    }
  }

  /// Add or edit the per-book note on one of this (own) list's books.
  /// 对话框见 [showBooklistNoteDialog]，这里只做保存与提示。
  Future<void> _editNote(Book book) async {
    final l10n = AppLocalizations.of(context)!;
    final note = await showBooklistNoteDialog(context, book);
    if (note == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final response = await ref.read(_provider.notifier).saveNote(book, note);
    if (!mounted) return;
    showAppSnackOn(
      messenger,
      response.success
          ? l10n.booklistNoteSaved
          : l10n.booklistNoteFailed(response.error ?? ''),
    );
  }

  /// 自己的单里长按书卡:批注/移出两项。面板见
  /// [showBooklistOwnBookActions]，这里只按选择分派。
  Future<void> _showOwnBookActions(Book book) async {
    final action = await showBooklistOwnBookActions(context, book);
    if (action == null || !mounted) return;
    switch (action) {
      case BooklistOwnBookAction.note:
        await _editNote(book);
      case BooklistOwnBookAction.remove:
        await _confirmRemove(book);
    }
  }

  List<Book> _visibleBooks(List<Book> books) {
    // 记忆化（审查 v2 P1-3）：列表实例、过滤词、排序都没变就复用上
    // 一次的结果——滚动 tick 不再每帧 O(n log n) 全量拷贝+排序。
    if (identical(books, _visibleCacheBooks) &&
        _query == _visibleCacheQuery &&
        _newestFirst == _visibleCacheSort &&
        _visibleCache != null) {
      return _visibleCache!;
    }
    final q = _query.toLowerCase();
    final out = q.isEmpty
        ? [...books]
        : books
              .where(
                (b) =>
                    b.title.toLowerCase().contains(q) ||
                    (b.author?.toLowerCase().contains(q) ?? false),
              )
              .toList();
    out.sort((a, b) {
      final ay = a.year ?? 0, by = b.year ?? 0;
      return _newestFirst ? by - ay : ay - by;
    });
    _visibleCacheBooks = books;
    _visibleCacheQuery = _query;
    _visibleCacheSort = _newestFirst;
    _visibleCache = out;
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(_provider);
    final controller = ref.read(_provider.notifier);
    final booklist = widget.args.booklist;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: controller.loadFirst,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            BooklistDetailAppBar(title: booklist.name),
            // 视差大字头(含作者行/玻璃胶囊/搜索排序行)。
            SliverToBoxAdapter(
              child: BooklistDetailHero(
                booklist: booklist,
                favorite: _favorite,
                pixels: _pixels,
                searchController: _searchController,
                newestFirst: _newestFirst,
                onToggleFavorite: _toggleFavorite,
                onShare: () => unawaited(_exportBookList()),
                onQueryChanged: (value) => setState(() => _query = value),
                onToggleSort: () =>
                    setState(() => _newestFirst = !_newestFirst),
                onClearSearch: () {
                  _searchController.clear();
                  setState(() => _query = '');
                },
              ),
            ),
            ..._body(state, controller),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(
    BooklistDetailState state,
    BooklistDetailController controller,
  ) {
    if (state.isLoading) {
      return const [BooklistDetailLoadingSliver()];
    }
    if (state.error != null) {
      return [
        BooklistDetailErrorSliver(
          message: state.error,
          onRetry: controller.loadFirst,
        ),
      ];
    }
    if (state.books.isEmpty) {
      return const [BooklistDetailEmptySliver()];
    }
    final visible = _visibleBooks(state.books);
    if (visible.isEmpty) {
      return const [BooklistDetailNoResultsSliver()];
    }
    return [
      BooklistDetailBookGrid(
        books: visible,
        canEdit: widget.args.canEdit,
        onTap: (book) => AppRoutes.openBookDetailForBook(context, book),
        onLongPress: widget.args.canEdit
            ? (book) => _showOwnBookActions(book)
            : null,
      ),
      // 按需加载尾巴：正在拉 → 转圈；上一页失败 → 重试行（书都留
      // 着，重试拉同一页）；还有下一页 → “加载更多”按钮。一页能装
      // 下的书单（hasMore 为 false）什么都不显示。
      if (state.isLoadingMore)
        const SliverToBoxAdapter(child: LoadingWidget.more())
      else if (state.loadMoreError != null)
        SliverToBoxAdapter(
          child: BooklistDetailPageErrorRow(
            message: state.loadMoreError!,
            onRetry: controller.loadMore,
          ),
        )
      else if (state.hasMore)
        SliverToBoxAdapter(
          child: BooklistDetailLoadMoreRow(onLoadMore: controller.loadMore),
        ),
    ];
  }
}
