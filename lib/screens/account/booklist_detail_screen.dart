import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/booklist_detail_provider.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_metrics.dart';
import '../../utils/app_snack.dart';
import '../../utils/cover_cache.dart';
import '../../widgets/booklist_quick_actions_sheet.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/loading_widget.dart';
import '../../widgets/motion/entrance.dart';

// Existing callers (main.dart routes, the profile page) import the args
// class from this screen's library.
export '../../providers/booklist_detail_provider.dart' show BooklistDetailArgs;

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
    if (_scrollController.position.extentAfter < 300) {
      ref.read(_provider.notifier).loadMore();
    }
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
  Future<void> _editNote(Book book) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: book.note ?? '');
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          book.note == null || book.note!.isEmpty
              ? l10n.booklistAddNote
              : l10n.booklistEditNote,
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          decoration: InputDecoration(labelText: l10n.booklistNote),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    controller.dispose();
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

  /// 自己的单里长按书卡:批注/移出两项。
  Future<void> _showOwnBookActions(Book book) async {
    final l10n = AppLocalizations.of(context)!;
    final note = book.note?.trim() ?? '';
    final action = await showModalBottomSheet<_OwnBookAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_rounded),
              title: Text(
                note.isEmpty ? l10n.booklistAddNote : l10n.booklistEditNote,
              ),
              onTap: () => Navigator.pop(sheetContext, _OwnBookAction.note),
            ),
            if (note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  note,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline_rounded),
              title: Text(l10n.booklistRemoveBook),
              onTap: () => Navigator.pop(sheetContext, _OwnBookAction.remove),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _OwnBookAction.note:
        await _editNote(book);
      case _OwnBookAction.remove:
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
    final l10n = AppLocalizations.of(context)!;
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
            SliverAppBar(
              pinned: true,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              surfaceTintColor: Colors.transparent,
              title: Text(
                booklist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // 视差大字头(含作者行/玻璃胶囊/搜索排序行)。
            SliverToBoxAdapter(
              child: _Hero(
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
            ..._body(l10n, state, controller),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(
    AppLocalizations l10n,
    BooklistDetailState state,
    BooklistDetailController controller,
  ) {
    if (state.isLoading) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 24),
            child: LoadingWidget(message: l10n.loading),
          ),
        ),
      ];
    }
    if (state.error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.error_outline,
            title: l10n.error,
            message: state.error,
            action: FilledButton(
              onPressed: controller.loadFirst,
              child: Text(l10n.retry),
            ),
          ),
        ),
      ];
    }
    if (state.books.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.collections_bookmark_outlined,
            title: l10n.noBooklistBooks,
          ),
        ),
      ];
    }
    final visible = _visibleBooks(state.books);
    if (visible.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.search_off_rounded,
            title: l10n.noBooksFound,
          ),
        ),
      ];
    }
    return [
      // 紧凑书架网格(2026-11-19 用户定稿):原 BookCard 封面高
      // (1.43 倍)+四行字,整屏显得又挤又长;这里改矮封面(0.78
      // 比例)+标题两行+作者一行,格式/年份/大小行删掉——详情页
      // 全都有,行距也拉开。
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
        sliver: SliverLayoutBuilder(
          builder: (context, constraints) {
            return SliverGrid.builder(
              gridDelegate: _shelfGridDelegate(
                context,
                constraints.crossAxisExtent,
              ),
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final book = visible[index];
                return MotionEntrance(
                  index: index,
                  child: BooklistShelfTile(
                    book: book,
                    onTap: () => AppRoutes.openBookDetailForBook(context, book),
                    onLongPress: widget.args.canEdit
                        ? () => _showOwnBookActions(book)
                        : null,
                  ),
                );
              },
            );
          },
        ),
      ),
      if (state.isLoadingMore)
        const SliverToBoxAdapter(child: LoadingWidget.more()),
    ];
  }
}

/// 书架网格的固定委托:窄屏 3 列、700 起 4 列、1000 起 5 列;
/// 格高 = 矮封面 + 三行文字(随系统字号缩放)。[width] 传不含
/// 页面 padding 的可视宽(SliverLayoutBuilder 的 crossAxisExtent)。
SliverGridDelegate _shelfGridDelegate(BuildContext context, double width) {
  final columns = width >= 1000
      ? 5
      : width >= 700
      ? 4
      : 3;
  const spacing = 12.0;
  const rowGap = 18.0;
  final cell = (width - spacing * (columns - 1)) / columns;
  final coverH = cell / 0.78;
  final ts = MediaQuery.textScalerOf(context);
  final textH =
      ts.scale(8) + ts.scale(33) + ts.scale(3) + ts.scale(16) + ts.scale(4);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    crossAxisSpacing: spacing,
    mainAxisSpacing: rowGap,
    childAspectRatio: cell / (coverH + textH),
  );
}

/// 书单详情一格的矮封面卡:封面(0.78)+ 标题两行 + 作者一行。
/// 公开类供测试与未来复用;点卡进书详情,长按(自己的单)出操作。
class BooklistShelfTile extends StatelessWidget {
  final Book book;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const BooklistShelfTile({
    super.key,
    required this.book,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.primaryContainer,
            Color.lerp(cs.primaryContainer, cs.surfaceContainerHighest, .6)!,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.menu_book_rounded,
          size: 26,
          color: cs.onPrimaryContainer.withValues(alpha: 0.55),
        ),
      ),
    );
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: AspectRatio(
              aspectRatio: 0.78,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: (book.cover ?? '').isEmpty
                    ? placeholder
                    : CachedNetworkImage(
                        imageUrl: book.cover!,
                        fit: BoxFit.cover,
                        memCacheWidth: coverCacheWidth(240, context),
                        memCacheHeight: coverCacheHeight(308, context),
                        placeholder: (_, __) => placeholder,
                        errorWidget: (_, __, ___) => placeholder,
                      ),
              ),
            ),
          ),
          SizedBox(height: MediaQuery.textScalerOf(context).scale(8)),
          Text(
            book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              height: 1.28,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            (book.author ?? '').isEmpty ? ' ' : book.author!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.35,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 自己的单里书卡长按面板的两项动作。
enum _OwnBookAction { note, remove }

/// 视差大字头 + 白色圆角 sheet(作者 chip、玻璃胶囊、搜索排序行)。
class _Hero extends StatelessWidget {
  final Booklist booklist;
  final bool favorite;

  /// 视差位移源（审查 v2 P1-3）：ValueListenable——滚动每 tick 只重
  /// 建头图里的视差层，不再整屏 setState。
  final ValueListenable<double> pixels;
  final TextEditingController searchController;
  final bool newestFirst;
  final VoidCallback onToggleFavorite;
  final VoidCallback onShare;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onToggleSort;
  final VoidCallback onClearSearch;

  const _Hero({
    required this.booklist,
    required this.favorite,
    required this.pixels,
    required this.searchController,
    required this.newestFirst,
    required this.onToggleFavorite,
    required this.onShare,
    required this.onQueryChanged,
    required this.onToggleSort,
    required this.onClearSearch,
  });

  static const double _heroHeight = 252;
  static const double _parallaxFactor = 0.35;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final previews = booklist.previewBooks.take(3).toList();
    return Column(
      children: [
        ClipRect(
          child: SizedBox(
            height: _heroHeight,
            // 视差位移随滚动上移背景,裁剪在头图区域内。ValueListenable
            // Builder 只重建这一层视差 Stack（审查 v2 P1-3）。
            child: ValueListenableBuilder<double>(
              valueListenable: pixels,
              builder: (context, pixels, _) {
                final dy =
                    -(pixels.clamp(0.0, _heroHeight) * _parallaxFactor);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Transform.translate(
                      offset: Offset(0, dy),
                      child: _HeroBackdrop(url: booklist.coverUrl),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.12),
                            Colors.black.withValues(alpha: 0.05),
                            Colors.black.withValues(alpha: 0.46),
                          ],
                          stops: const [0.0, 0.5, 1.0],
                        ),
                      ),
                    ),
                    Positioned(
                      top: 74 + dy * 0.4,
                      left: 0,
                      right: 0,
                      child: _CoverStack(previews: previews),
                    ),
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: 18,
                      child: Text(
                        booklist.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          height: 1.25,
                          shadows: [
                            Shadow(color: Colors.black45, blurRadius: 10)
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        // 白色圆角 sheet 上探头图 16px(视觉稿的层叠感)。
        Transform.translate(
          offset: const Offset(0, -16),
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(26),
            ),
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _AuthorChip(booklist: booklist),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _GlassPill(
                      icon: favorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      iconColor: favorite ? const Color(0xFFFF6B6B) : null,
                      label: favorite
                          ? AppLocalizations.of(context)!.booklistFavorited
                          : AppLocalizations.of(context)!.favoriteBooklist,
                      onTap: onToggleFavorite,
                    ),
                    const SizedBox(width: 10),
                    _GlassPill(
                      icon: Icons.ios_share_rounded,
                      label: AppLocalizations.of(context)!.share,
                      onTap: onShare,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _ListSearchBar(
                  controller: searchController,
                  newestFirst: newestFirst,
                  onChanged: onQueryChanged,
                  onToggleSort: onToggleSort,
                  onClear: onClearSearch,
                ),
                if (booklist.description.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _ExpandableText(
                      text: booklist.description,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 头图背景:书单封面高斯模糊;无封面/失败时走主题渐变,不留死色。
class _HeroBackdrop extends StatelessWidget {
  final String url;

  const _HeroBackdrop({required this.url});

  /// 模糊滤镜提为常量（审查 v2 P1-3）：此前每次 build 新建一个
  /// ImageFilter 实例，render object 每帧收到"新"滤镜（无 == 语义）
  /// 触发重设——滚动每帧都白做一次。
  static final ui.ImageFilter _backdropBlur = ui.ImageFilter.blur(
    sigmaX: 24,
    sigmaY: 24,
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.primaryContainer,
            Color.lerp(cs.primaryContainer, cs.tertiaryContainer, 0.55)!,
          ],
        ),
      ),
    );
    if (url.isEmpty) return fallback;
    return ImageFiltered(
      imageFilter: _backdropBlur,
      child: CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        memCacheWidth: coverCacheWidth(600, context),
        memCacheHeight: coverCacheHeight(600, context),
        placeholder: (_, __) => fallback,
        errorWidget: (_, __, ___) => fallback,
      ),
    );
  }
}

/// 前三本书封面的扇形堆叠(±11°),中卡略抬。无预览时画三块
/// 主题色占位卡,布局保持。
class _CoverStack extends StatelessWidget {
  final List<Book> previews;

  const _CoverStack({required this.previews});

  static const _angles = [-11.0, 0.0, 11.0];
  static const _dx = [-46.0, 0.0, 46.0];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tiles = <Widget>[];
    for (var i = 0; i < 3; i++) {
      final book = i < previews.length ? previews[i] : null;
      final url = book?.cover ?? '';
      tiles.add(
        Transform.translate(
          offset: Offset(_dx[i], i == 1 ? -8 : 0),
          child: Transform.rotate(
            angle: _angles[i] * 3.14159265 / 180,
            child: Container(
              width: 78,
              height: 108,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.30),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.lerp(cs.primaryContainer, cs.secondary, i * 0.3)!,
                    Color.lerp(cs.surface, cs.tertiaryContainer, i * 0.2)!,
                  ],
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: url.isEmpty
                  ? null
                  : CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      memCacheWidth: coverCacheWidth(78, context),
                      memCacheHeight: coverCacheHeight(108, context),
                      placeholder: (_, __) => const SizedBox.shrink(),
                      errorWidget: (_, __, ___) => const SizedBox.shrink(),
                    ),
            ),
          ),
        ),
      );
    }
    return SizedBox(
      height: 124,
      child: Stack(
        alignment: Alignment.center,
        children: [
          for (final t in tiles)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: t,
              ),
            ),
        ],
      ),
    );
  }
}

/// 头像 chip 行:头像 + 作者 · N 本书 · 浏览量;作者可点进主页。
class _AuthorChip extends StatelessWidget {
  final Booklist booklist;

  const _AuthorChip({required this.booklist});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final count = booklist.count;
    final meta = <String>[
      if (count != null) AppLocalizations.of(context)!.booklistBookCount(count),
      if (booklist.views.isNotEmpty) booklist.views,
    ].join(' · ');
    final segments =
        Uri.tryParse(booklist.authorProfile)?.pathSegments ?? const [];
    final userId = segments.length >= 2 ? int.tryParse(segments[1]) : null;
    final userHash = segments.length >= 3 ? segments[2] : null;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: userId == null
          ? null
          : () => AppRoutes.openUserProfile(
              context,
              UserProfileArgs(
                userId: userId,
                userName: booklist.author,
                userAvatar: booklist.authorAvatar,
                userHash: userHash,
              ),
            ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RoundAvatar(url: booklist.authorAvatar),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                meta.isEmpty ? booklist.author : '${booklist.author} · $meta',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundAvatar extends StatelessWidget {
  final String url;

  const _RoundAvatar({required this.url});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipOval(
      child: SizedBox(
        width: 24,
        height: 24,
        child: ColoredBox(
          color: cs.surfaceContainerHighest,
          child: url.isEmpty
              ? null
              : CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  memCacheWidth: coverCacheWidth(24, context),
                  placeholder: (_, __) => const SizedBox.shrink(),
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
        ),
      ),
    );
  }
}

/// 玻璃质感胶囊(半透白 + 内描边 + 轻投影),详情页的两个主动作。
class _GlassPill extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String label;
  final VoidCallback onTap;

  const _GlassPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.white.withValues(alpha: 0.62),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withValues(alpha: 0.75)),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.shadow.withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 17,
                color: iconColor ?? theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 6),
              Text(label, style: theme.textTheme.labelLarge),
            ],
          ),
        ),
      ),
    );
  }
}

/// 书单内搜索 + 排序切换(客户端,作用于已加载页)。
class _ListSearchBar extends StatelessWidget {
  final TextEditingController controller;
  final bool newestFirst;
  final ValueChanged<String> onChanged;
  final VoidCallback onToggleSort;
  final VoidCallback onClear;

  const _ListSearchBar({
    required this.controller,
    required this.newestFirst,
    required this.onChanged,
    required this.onToggleSort,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 20, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) => TextField(
                controller: controller,
                onChanged: onChanged,
                textInputAction: TextInputAction.search,
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: l10n.searchBooklists,
                  hintStyle: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                  suffixIcon: value.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, size: 16),
                          onPressed: onClear,
                        ),
                ),
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onToggleSort,
            icon: const Icon(Icons.swap_vert_rounded, size: 16),
            label: Text(
              newestFirst ? l10n.booklistSortNewest : l10n.booklistSortUpdated,
              style: theme.textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExpandableText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  const _ExpandableText({required this.text, this.style});

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  static const int _collapsedLines = 3;
  bool _expanded = false;

  // Memoized overflow measurement: the TextPainter is only rebuilt
  // when the text, style, text direction, or available width changes.
  // Rebuilding it on every layout is wasted work — the description
  // does not change between builds.
  String? _measuredText;
  TextStyle? _measuredStyle;
  TextDirection? _measuredDirection;
  double? _measuredWidth;
  bool _overflows = false;

  bool _measureOverflow(BuildContext context, double maxWidth) {
    final direction = Directionality.of(context);
    if (_measuredText == widget.text &&
        _measuredStyle == widget.style &&
        _measuredDirection == direction &&
        _measuredWidth == maxWidth) {
      return _overflows;
    }
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: _collapsedLines,
      textDirection: direction,
    )..layout(maxWidth: maxWidth);
    final overflows = painter.didExceedMaxLines;
    painter.dispose();
    _measuredText = widget.text;
    _measuredStyle = widget.style;
    _measuredDirection = direction;
    _measuredWidth = maxWidth;
    _overflows = overflows;
    return _overflows;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final overflows = _measureOverflow(context, constraints.maxWidth);
        final text = Text(
          widget.text,
          style: widget.style,
          maxLines: _expanded ? null : _collapsedLines,
          overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
        );
        if (!overflows) return text;
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedSize(
                duration: AppMotion.standard,
                alignment: Alignment.topCenter,
                child: text,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
