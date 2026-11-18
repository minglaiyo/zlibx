import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/display_book.dart';
import '../theme/app_colors.dart';
import '../theme/app_layout.dart';
import '../theme/app_metrics.dart';
import '../theme/motion.dart';
import '../utils/cover_cache.dart';
import 'book_cover_backdrop.dart';
import 'cover_placeholder.dart';

/// 网格卡片书名槽位：字号 / 行高倍数 / 行数。
///
/// 这个乘积只是**下限**（见 _buildGridInfo 里的 ConstrainedBox），
/// 不是定高：Skia 会把 14×1.2=16.8 的行盒进位成 17.0，两行真实需要
/// 34.0，用 SizedBox 钉死 33.6 就会把末行再裁掉零点几像素。留下限
/// 的话，两行书名按真实高度排，单行书名补足到同一档，同屏卡片版式
/// 依旧对齐。
///
/// 放在文件顶层（而不是 [_BookCardState] 里）：[BookCard.gridHeightFor]
/// 算一格多高时要把这块信息区算进去，两边读的必须是同一个数。
const double _titleFontSize = 14;
const double _titleLineHeight = 1.2;
const int _titleMaxLines = 2;
double get _titleSlotHeight =>
    _titleFontSize * _titleLineHeight * _titleMaxLines;

class BookCard extends StatefulWidget {
  final DisplayBook book;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool compact;
  final bool showSourceBadge;
  final bool searchResult;

  /// 纯封面卡：封面 + 封面右下角那一枚评分，不带下面的书名 / 作者 /
  /// 格式 / 大小信息区。热门、最新上架两页用它，观感和首页推荐一致。
  /// 与 [compact] 的区别只有评分角标：compact 走 [BookCoverBackdrop]
  /// 那套带模糊底 + z 站角标的首页卡，这里保留 `_buildFullCover` 的
  /// 直接铺封面 + score 角标。
  final bool coverOnly;

  /// 是否启用封面共享元素转场（Hero，tag `cover-<book.id>`，与
  /// 详情页 [BookHeroSection] 配对）。默认关闭——同一屏可能同屏
  /// 重复 id 的调用方（如首页多个分区）不要开，避免 Hero 冲突。
  final bool heroEnabled;

  const BookCard({
    super.key,
    required this.book,
    this.onTap,
    this.onLongPress,
    this.compact = false,
    this.showSourceBadge = false,
    this.searchResult = false,
    this.coverOnly = false,
    this.heroEnabled = false,
  });

  /// 首页纯封面卡片的高度。
  static double compactHeightFor(double width) =>
      BookCoverBackdrop.heightFor(width);

  /// 网格卡片信息区（[_titleSlotHeight] 两行书名 + 分类行 + 作者行 +
  /// 大小行 + 内边距）在 1 倍字号下的内容高度，按系统字号缩放。
  static const double _gridInfoHeight = 116;

  /// 封面宽高比，与 [BookCoverBackdrop] 保持一致。纯封面那两页（热门 /
  /// 最新上架）关掉自适应时那份固定 delegate 也读这个数，比例只有一个
  /// 来源。
  static const double coverAspectRatio = 0.7;

  /// 带信息区的网格卡（最新上架 / 热门 / 同类 / 搜索结果）在自适应档下
  /// 一格该多高。
  ///
  /// 这些页面原本用固定的 `childAspectRatio`（0.65 / 0.60）：两列时卡片
  /// ≈183dp 宽，信息区之外还剩 ~164dp 封面，够用；一旦按首页的密度排到
  /// 三列（≈113dp 宽），同样的比例只给封面留下 192-116 ≈ 76dp，封面被
  /// 裁成一条横带。比例改成"封面按 0.7 给足 + 信息区按内容"，格子就长
  /// 高了，列数可以和首页一致而封面不塌。关掉开关时这些页面仍走各自
  /// 原来的固定比例，一格都不差。
  static double gridHeightFor(BuildContext context, double width) =>
      width / coverAspectRatio +
      _gridInfoHeight *
          MediaQuery.textScalerOf(context).scale(_titleFontSize) /
          _titleFontSize;

  /// 列表页网格（最新上架 / 热门 / 同类 / 搜索结果及其骨架）在自适应档
  /// 下共用的委托。列数、留白、间距都问 [AppLayout]，和首页同一套规则，
  /// 所以那个开关一开就是整站一起变；格高按 [gridHeightFor] 算。
  ///
  /// 做成一个工厂而不是五处抄写：这几页必须逐像素同步，搜索结果还有一
  /// 份骨架要跟着它，抄一遍就多一处会漏的地方。关掉开关时各页仍用自己
  /// 那份固定 delegate，不进这里。
  ///
  /// [coverOnly] 给的是纯封面那两页（最新上架 / 热门）：列数、留白、间距
  /// 一个字不改，只把格高从"封面 + 信息区"换成首页那条 `width / 0.7`
  /// （[compactHeightFor]），信息区没了，格子自然矮下来。同类和搜索结果
  /// 仍要书名信息，走默认的那档。
  static SliverGridDelegate adaptiveGridDelegate(
    BuildContext context,
    double width, {
    bool coverOnly = false,
  }) {
    final columns = AppLayout.gridColumns(width);
    final gutter = AppLayout.pageGutter(width);
    final gridWidth = (width - gutter * 2).clamp(0.0, double.infinity);
    final cellWidth =
        ((gridWidth - AppLayout.gridSpacing * (columns - 1)) / columns).clamp(
          0.0,
          double.infinity,
        );
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: AppLayout.gridSpacing,
      mainAxisSpacing: 12,
      mainAxisExtent: coverOnly
          ? compactHeightFor(cellWidth)
          : gridHeightFor(context, cellWidth),
    );
  }

  @override
  State<BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<BookCard> {
  // Press feedback
  double _scale = 1.0;

  bool get _hasCover => widget.book.cover?.isNotEmpty ?? false;

  void _onTapDown(TapDownDetails details) {
    setState(() => _scale = 0.96);
  }

  void _onTapUp(TapUpDetails details) {
    setState(() => _scale = 1.0);
  }

  void _onTapCancel() {
    setState(() => _scale = 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 纯封面两种卡（首页 compact、列表页 coverOnly）共用首页那套小圆角
    // + 浅投影，否则热门/最新上架换成封面卡后圆角还是 20，和推荐对不上。
    final flatCover = widget.compact || widget.coverOnly;
    final borderRadius = BorderRadius.circular(
      flatCover ? 4 : (widget.searchResult ? 12 : 20),
    );

    // Soft Card UI with press-scale feedback
    return AnimatedScale(
      scale: _scale,
      duration: MotionPress.duration,
      curve: MotionPress.curve,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardTheme.color,
          borderRadius: borderRadius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: flatCover
                    ? (isDark ? 0.08 : 0.025)
                    : (isDark ? 0.2 : 0.05),
              ),
              blurRadius: flatCover ? 4 : 10,
              offset: Offset(0, flatCover ? 2 : 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: Material(
            color: Colors.transparent,
            child: GestureDetector(
              onTapDown: _onTapDown,
              onTapUp: _onTapUp,
              onTapCancel: _onTapCancel,
              child: InkWell(
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                child: widget.coverOnly
                    ? _buildCoverOnly()
                    : widget.compact
                    ? _buildCoverBackdrop()
                    : _buildGridCard(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 网格卡片（最新上架 / 热门 / 同类 / 搜索结果共用）：封面与信息区
  /// 的分配。
  ///
  /// 非搜索分支里，信息区不再包 Expanded——之前是固定一档
  /// （flex 2 / 5），窄屏（360dp，卡片宽 ~158）上那档只有 ~97px，
  /// 扣掉内边距、格式行、作者、大小行，留给两行书名只剩 ~18px，
  /// 第二行只露半截（2026-11-15 用户截图：最新上架"阶级与话语之间——
  /// 左翼…"）。书名是内容、封面是装饰，余量该由封面吸收；书名槽位
  /// 按 [_titleSlotHeight] 的两行下限排，同屏卡片版式依旧对齐。
  ///
  /// 搜索分支保持原样：它的信息区本来就按内容排，flex 2 那档
  /// （0.60 比例下 ~108px）装得下，动它只会改搜索结果页的封面高度。
  Widget _buildGridCard() {
    if (widget.searchResult) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: _buildFullCover()),
          Expanded(flex: 2, child: _buildSearchInfo()),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Cover Image（吃掉信息区之外的全部高度）
        Expanded(child: _buildFullCover()),

        // 2. Info Content（按内容定高）
        _buildGridInfo(),
      ],
    );
  }

  Widget _buildGridInfo() {
    // 槽位随系统字号缩放：Text 的行高是按缩放后的字号算的，
    // 固定 33.6 在 1.5 倍字号下又变成裁半截——正是要修的那个毛病。
    final titleScale =
        MediaQuery.textScalerOf(context).scale(_titleFontSize) / _titleFontSize;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Level 2: Category/Tag (Orange, Small) - ABOVE Title
          _buildMetaRow(),

          const SizedBox(height: 4),

          // Level 1: Title (Black, Bold, Large)
          ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: _titleSlotHeight * titleScale,
            ),
            child: Text(
              widget.book.title,
              maxLines: _titleMaxLines,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                height: _titleLineHeight,
                fontSize: _titleFontSize,
              ),
            ),
          ),

          // Level 3: Author (Grey, Secondary)
          if (widget.book.author != null && widget.book.author!.isNotEmpty)
            Text(
              widget.book.author!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontSize: 11),
            ),

          const SizedBox(height: 8),

          // Level 3: Bottom row (Stars/Size)
          _buildBottomRow(),
        ],
      ),
    );
  }

  Widget _buildCoverBackdrop() {
    final sourceLabel = widget.showSourceBadge
        ? AppLocalizations.of(context)!.sourceZlibrary
        : null;

    Widget content({ImageProvider? image, bool loading = false}) {
      final cover = BookCoverBackdrop(
        image: image,
        placeholder: loading
            ? _buildShimmer(showBookInfo: true)
            : _buildPlaceholder(showBookInfo: true),
        book: widget.book,
        sourceLabel: sourceLabel,
      );
      if (sourceLabel == null) return cover;

      return Stack(
        fit: StackFit.expand,
        children: [
          cover,
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Align(
              alignment: Alignment.topRight,
              child: IgnorePointer(
                child: ExcludeSemantics(child: _buildSourceBadge(sourceLabel)),
              ),
            ),
          ),
        ],
      );
    }

    if (!_hasCover) return content();

    // 首页只加载一次封面，保留原有加载和错误状态。解码尺寸按
    // 实际渲染尺寸算：宽是卡片宽，高由 BookCoverBackdrop 的
    // 0.7 宽高比（见 heightFor）定。要图与解码同宽（高清版）。
    return LayoutBuilder(
      builder: (context, constraints) {
        final cacheWidth = coverCacheWidth(constraints.maxWidth, context);
        final cacheHeight = coverCacheHeight(
          BookCoverBackdrop.heightFor(constraints.maxWidth),
          context,
        );
        return CachedNetworkImage(
          imageUrl: coverUrlAtWidth(widget.book.cover!, cacheWidth),
          memCacheWidth: cacheWidth,
          memCacheHeight: cacheHeight,
          fadeInDuration: AppMotion.slow,
          fadeOutDuration: AppMotion.fast,
          httpHeaders: const {'Connection': 'keep-alive'},
          imageBuilder: (context, imageProvider) {
            return _maybeHero(content(image: imageProvider));
          },
          placeholder: (context, url) => content(loading: true),
          errorWidget: (context, url, error) {
            return content();
          },
        );
      },
    );
  }

  /// 有封面且调用方启用时包 Hero（无封面的占位图不参与转场）。
  Widget _maybeHero(Widget cover) {
    if (!widget.heroEnabled) return cover;
    return Hero(tag: 'cover-${widget.book.id}', child: cover);
  }

  /// 纯封面卡（热门 / 最新上架）：视觉上只有封面 + 封面上那枚评分，但
  /// 读屏还得念得出书名——信息区被拿掉，这块语义不能跟着一起丢。首页
  /// compact 卡由 [BookCoverBackdrop] 自己的 Semantics 兜住，这里同一条
  /// 道理，label 用书名、作者、评分拼的逗号串，不含需要翻译的词。
  Widget _buildCoverOnly() {
    final author = widget.book.author;
    final score = widget.book.score;
    return Semantics(
      label: [
        widget.book.title,
        if (author != null && author.isNotEmpty) author,
        if (score != null && score.isNotEmpty) score,
      ].join(', '),
      excludeSemantics: true,
      child: _buildFullCover(),
    );
  }

  Widget _buildFullCover() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cacheWidth = coverCacheWidth(constraints.maxWidth, context);
        final score = widget.book.score;
        final meta = widget.book.meta;
        final hasScore = score != null && score.isNotEmpty;
        final hasMeta = meta != null && meta.isNotEmpty;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (_hasCover)
              CachedNetworkImage(
                imageUrl: coverUrlAtWidth(widget.book.cover!, cacheWidth),
                fit: BoxFit.cover,
                memCacheWidth: cacheWidth,
                fadeInDuration: AppMotion.slow,
                fadeOutDuration: AppMotion.fast,
                httpHeaders: const {'Connection': 'keep-alive'},
                imageBuilder: (context, imageProvider) {
                  return _maybeHero(
                    Image(image: imageProvider, fit: BoxFit.cover),
                  );
                },
                errorWidget: (context, url, error) {
                  return _buildPlaceholder();
                },
                placeholder: (context, url) => _buildShimmer(),
              )
            else
              _buildPlaceholder(),
            // Rating lives on the cover for every card now (not only
            // search results): the text-row ★ in _buildBottomRow is
            // gone. The filesize label stays search-only — it still
            // has its own spot in the bottom row elsewhere.
            if (hasScore || (widget.searchResult && hasMeta))
              Positioned(
                right: 8,
                bottom: 8,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (hasScore) _buildCoverLabel(score, rating: true),
                    if (hasScore && widget.searchResult && hasMeta)
                      const SizedBox(height: 4),
                    if (widget.searchResult && hasMeta) _buildCoverLabel(meta),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildCoverLabel(String text, {bool rating = false}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (rating) ...[
              const Icon(
                Icons.star_rounded,
                size: 14,
                color: AppColors.ratingStar,
              ),
              const SizedBox(width: 3),
            ],
            Text(
              text,
              style: TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: rating ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchInfo() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildMetaRow(),
          const SizedBox(height: 4),
          Text(
            widget.book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(height: 1.2, fontSize: 14),
          ),
          if (widget.book.author != null && widget.book.author!.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              widget.book.author!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSourceBadge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.sourceBadge,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.library_books_rounded, size: 14, color: Colors.white),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build the top meta row (tag + tagExtra)
  Widget _buildMetaRow() {
    final hasTag = widget.book.tag != null && widget.book.tag!.isNotEmpty;
    final hasTagExtra =
        widget.book.tagExtra != null && widget.book.tagExtra!.isNotEmpty;

    if (!hasTag && !hasTagExtra) {
      // Return a minimal spacer if no meta info available
      return const SizedBox(height: 12);
    }

    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (hasTag)
          Flexible(
            child: Text(
              widget.book.tag!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.secondary,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
        if (hasTag && hasTagExtra) const SizedBox(width: 4),
        // 两边都得是 Flexible：自适应三列把卡片压到 ~100dp，字号再放大
        // 一档（系统字体 1.5×）时"分类 + 年份"这行的自然宽度就超过格子，
        // 后半段不包 Flexible 就是整行溢出（黄黑斜条）。包上之后按内容
        // 分宽度、挤不下各自省略号。
        if (hasTagExtra)
          Flexible(
            child: Text(
              hasTag ? '• ${widget.book.tagExtra}' : widget.book.tagExtra!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10),
            ),
          ),
      ],
    );
  }

  /// Build the bottom row (meta only — the rating lives on the cover
  /// badge, see _buildFullCover).
  Widget _buildBottomRow() {
    final hasMeta = widget.book.meta != null && widget.book.meta!.isNotEmpty;

    if (!hasMeta) {
      // Show nothing if no data available
      return const SizedBox.shrink();
    }

    final cs = Theme.of(context).colorScheme;
    // 靠右对齐用 mainAxisAlignment 而不是 Spacer()：Spacer 是 flex 1 的
    // 空块，格子窄 + 字号大的时候它照样要吃掉一半宽度，右边那个文件大小
    // 就溢出到卡片外。end 对齐下文案短时贴右、长时占满并可省略号。
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: Text(
            widget.book.meta!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// Placeholder when no cover or load error — shared static cover icon.
  Widget _buildPlaceholder({bool showBookInfo = false}) {
    return _withFallbackBookInfo(
      const CoverPlaceholder.static(),
      showBookInfo: showBookInfo,
    );
  }

  /// Loading shimmer — the shared animated cover placeholder.
  Widget _buildShimmer({bool showBookInfo = false}) {
    return _withFallbackBookInfo(
      const CoverPlaceholder.shimmer(),
      showBookInfo: showBookInfo,
    );
  }

  Widget _withFallbackBookInfo(
    Widget background, {
    required bool showBookInfo,
  }) {
    if (!showBookInfo) return background;
    final author = widget.book.author?.trim();
    return Stack(
      fit: StackFit.expand,
      children: [
        background,
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Color(0xCC183327)],
              stops: [0.35, 1],
            ),
          ),
        ),
        Positioned(
          left: 10,
          right: 10,
          bottom: 11,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.book.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
              if (author != null && author.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 10.5,
                    height: 1.2,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
