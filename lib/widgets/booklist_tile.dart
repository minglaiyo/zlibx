import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../l10n/generated/app_localizations.dart';
import '../utils/cover_cache.dart';
import 'booklist_quick_actions_sheet.dart';
import 'motion/entrance.dart';

/// 两列上下滑动的封面瀑布流(2026-11-19 用户定稿:书单模块的列表
/// 统一"上下两列、上下滑动",替代横向封面流)。
///
/// 卡片按左右列交替分列,每列在 1.28 / 1.52 两档宽高比间轮换形成
/// 错落;[MotionEntrance] 按全局序号错峰(右列晚一档,呈 L 形瀑布)。
/// 本组件不自带滚动容器——页面外层给 SingleChildScrollView 或
/// SliverToBoxAdapter,分页加载由调用方的竖向滚动监听驱动。
class BooklistMasonryGrid extends StatelessWidget {
  final List<Booklist> lists;
  final ValueChanged<Booklist> onOpen;
  final ValueChanged<Booklist> onLongPress;
  final bool showFavoriteBadge;
  final EdgeInsetsGeometry padding;

  const BooklistMasonryGrid({
    super.key,
    required this.lists,
    required this.onOpen,
    required this.onLongPress,
    this.showFavoriteBadge = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  });

  @override
  Widget build(BuildContext context) {
    final left = <({Booklist list, int globalIndex})>[];
    final right = <({Booklist list, int globalIndex})>[];
    for (var i = 0; i < lists.length; i++) {
      final cell = (list: lists[i], globalIndex: i);
      (i.isEven ? left : right).add(cell);
    }
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _column(context, left, isRight: false)),
          const SizedBox(width: 10),
          Expanded(child: _column(context, right, isRight: true)),
        ],
      ),
    );
  }

  Widget _column(
    BuildContext context,
    List<({Booklist list, int globalIndex})> items, {
    required bool isRight,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _masonryCard(
              list: items[i].list,
              globalIndex: items[i].globalIndex,
              // 错落感来源:按格序在两档比例间轮换,右列错开半档。
              aspectRatio: (i + (isRight ? 1 : 0)).isEven ? 1.28 : 1.52,
              showFavoriteBadge: showFavoriteBadge,
              onOpen: onOpen,
              onLongPress: onLongPress,
            ),
          ),
      ],
    );
  }
}

/// One masonry cover card: the aspect-ratio alternation, the entrance
/// stagger ([MotionEntrance] by global index) and the tap/long-press
/// wiring. Shared by the eager [BooklistMasonryGrid] and the lazy
/// [BooklistMasonrySliverList] so the two render identically.
Widget _masonryCard({
  required Booklist list,
  required int globalIndex,
  required double aspectRatio,
  required bool showFavoriteBadge,
  required ValueChanged<Booklist> onOpen,
  required ValueChanged<Booklist> onLongPress,
}) {
  return MotionEntrance(
    index: globalIndex,
    child: BooklistCoverCard(
      list: list,
      aspectRatio: aspectRatio,
      showFavoriteBadge: showFavoriteBadge,
      onTap: () => onOpen(list),
      onLongPress: () => onLongPress(list),
    ),
  );
}

/// Lazy version of [BooklistMasonryGrid] for the booklists home list:
/// the same two-column cover flow, but rows are built on demand by a
/// [SliverList] instead of all up front in two [Column]s.
///
/// Each sliver row holds the pair the eager grid would put at the same
/// column depth (left = lists[2k], right = lists[2k+1]), so the
/// aspect-ratio alternation and the [MotionEntrance] global indices
/// match the eager grid exactly.
///
/// The trade-off: the two columns no longer flow independently — a
/// row's height is its taller card, so the stagger resets every row
/// instead of accumulating down the columns. For a paginated home
/// list that is the price of lazy build; the related-booklists page
/// (few items, single fetch) keeps the eager grid.
class BooklistMasonrySliverList extends StatelessWidget {
  final List<Booklist> lists;
  final ValueChanged<Booklist> onOpen;
  final ValueChanged<Booklist> onLongPress;
  final bool showFavoriteBadge;

  const BooklistMasonrySliverList({
    super.key,
    required this.lists,
    required this.onOpen,
    required this.onLongPress,
    this.showFavoriteBadge = true,
  });

  @override
  Widget build(BuildContext context) {
    final rowCount = (lists.length + 1) ~/ 2;
    return SliverList(
      delegate: SliverChildBuilderDelegate((context, row) {
        final left = lists[row * 2];
        final rightIndex = row * 2 + 1;
        final right = rightIndex < lists.length ? lists[rightIndex] : null;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _masonryCard(
                  list: left,
                  globalIndex: row * 2,
                  aspectRatio: row.isEven ? 1.28 : 1.52,
                  showFavoriteBadge: showFavoriteBadge,
                  onOpen: onOpen,
                  onLongPress: onLongPress,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: right == null
                    ? const SizedBox.shrink()
                    : _masonryCard(
                        list: right,
                        globalIndex: rightIndex,
                        aspectRatio: row.isEven ? 1.52 : 1.28,
                        showFavoriteBadge: showFavoriteBadge,
                        onOpen: onOpen,
                        onLongPress: onLongPress,
                      ),
              ),
            ],
          ),
        );
      }, childCount: rowCount),
    );
  }
}

/// 书单封面大卡(2026-11-19 整体重设计的核心单元,「封面即内容」)。
///
/// 整卡就是一张封面:底部暗色渐变遮罩上叠白色书名与「作者 · N 本书」,
/// 右上角半透明圆徽心形=收藏/取消收藏(直调站点写接口,成功后翻转
/// 本地镜像;与长按面板同一实现)。用于:
///  * 书单主页的横向封面流(定宽高 [width]/[height]);
///  * 关联书单页的双列瀑布流(只给 [aspectRatio],宽度吃满列宽,
///    两列交错不同比例形成错落感)。
/// 点击=进书单详情;长按=弹收藏/分享快捷面板(调用方可不给)。
class BooklistCoverCard extends StatefulWidget {
  final Booklist list;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 定宽定高模式(封面流)。给了 height 就按 SizedBox 摆;
  /// 否则按 [aspectRatio] 自适应宽(瀑布流)。
  final double? width;
  final double? height;
  final double aspectRatio;

  /// 心形徽标显隐:调用方页面不想在心形以外再给收藏入口时可关。
  final bool showFavoriteBadge;

  const BooklistCoverCard({
    super.key,
    required this.list,
    this.onTap,
    this.onLongPress,
    this.width,
    this.height,
    this.aspectRatio = 158 / 224,
    this.showFavoriteBadge = true,
  });

  @override
  State<BooklistCoverCard> createState() => _BooklistCoverCardState();
}

class _BooklistCoverCardState extends State<BooklistCoverCard> {
  /// 收藏态本地镜像:打开时取卡片属性(发现/收藏 tab 带真实值,
  /// 关联书单区块不带 → 空心),写入成功后翻转。
  late bool _favorite = widget.list.isFavorite;

  @override
  void didUpdateWidget(covariant BooklistCoverCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.list.id != widget.list.id) {
      _favorite = widget.list.isFavorite;
    }
  }

  Future<void> _toggleFavorite() async {
    final want = !_favorite;
    final ok = await runBooklistFavorite(
      context,
      widget.list,
      wantFavorite: want,
    );
    if (ok && mounted) setState(() => _favorite = want);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;

    Widget card = Padding(
      padding: const EdgeInsets.all(2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          // 涟漪做在 Stack 外层:遮罩上的文字层不单独吃手势,
          // 整卡点穿到 InkWell;心形自己带按钮,先到先得。
          borderRadius: BorderRadius.circular(16),
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _CoverArt(url: widget.list.coverUrl, cs: cs),
                // 底部遮罩:上缘透明,保证白字封面再花也读得清。
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.0),
                        Colors.black.withValues(alpha: 0.18),
                        Colors.black.withValues(alpha: 0.78),
                      ],
                      stops: const [0.42, 0.62, 1.0],
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 34,
                  bottom: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.list.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                          shadows: [
                            Shadow(
                              color: Colors.black54,
                              blurRadius: 6,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _metaText(l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.showFavoriteBadge)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: _HeartBadge(
                      favorite: _favorite,
                      onTap: _toggleFavorite,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    card = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: card,
    );

    // 长按 = 收藏/分享面板;在卡片外层做,避免 InkWell 竞争。
    final Widget sized = widget.height != null
        ? SizedBox(width: widget.width, height: widget.height, child: card)
        : AspectRatio(aspectRatio: 1 / widget.aspectRatio, child: card);
    return sized;
  }

  String _metaText(AppLocalizations l10n) {
    final count = widget.list.count;
    final parts = <String>[
      if (widget.list.author.isNotEmpty) widget.list.author,
      if (count != null) l10n.booklistBookCount(count),
    ];
    return parts.isEmpty ? ' ' : parts.join(' · ');
  }
}

/// 封面图:空/失败落到按书单配色生成的柔色渐变底,不留白块。
class _CoverArt extends StatelessWidget {
  final String url;
  final ColorScheme cs;

  const _CoverArt({required this.url, required this.cs});

  @override
  Widget build(BuildContext context) {
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.primaryContainer,
            Color.lerp(cs.primaryContainer, cs.surfaceContainerHighest, 0.6)!,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.collections_bookmark_rounded,
          size: 40,
          color: cs.onPrimaryContainer.withValues(alpha: 0.55),
        ),
      ),
    );
    if (url.isEmpty) return placeholder;
    return CachedNetworkImage(
      imageUrl: url,
      cacheManager: coverCacheManager,
      fit: BoxFit.cover,
      memCacheWidth: coverCacheWidth(320, context),
      memCacheHeight: coverCacheHeight(450, context),
      placeholder: (_, __) => placeholder,
      errorWidget: (_, __, ___) => placeholder,
    );
  }
}

/// 半透明圆底心形徽标;点击带弹跳缩放反馈(无障碍时跳过动画)。
class _HeartBadge extends StatefulWidget {
  final bool favorite;
  final VoidCallback onTap;

  const _HeartBadge({required this.favorite, required this.onTap});

  @override
  State<_HeartBadge> createState() => _HeartBadgeState();
}

class _HeartBadgeState extends State<_HeartBadge> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 1.18 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutBack,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.42),
              shape: BoxShape.circle,
            ),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                widget.favorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                size: 17,
                color: widget.favorite ? const Color(0xFFFF6B6B) : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
