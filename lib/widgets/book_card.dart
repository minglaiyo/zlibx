import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../l10n/generated/app_localizations.dart';
import '../models/display_book.dart';
import '../theme/app_metrics.dart';
import '../utils/cover_cache.dart';
import 'book_cover_backdrop.dart';
import 'cover_placeholder.dart';

class BookCard extends StatefulWidget {
  final DisplayBook book;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool compact;
  final bool showSourceBadge;
  final bool searchResult;

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
    this.heroEnabled = false,
  });

  /// 首页纯封面卡片的高度。
  static double compactHeightFor(double width) =>
      BookCoverBackdrop.heightFor(width);

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
    final borderRadius = BorderRadius.circular(
      widget.compact ? 4 : (widget.searchResult ? 12 : 20),
    );

    // Soft Card UI with press-scale feedback
    return AnimatedScale(
      scale: _scale,
      duration: AppMotion.fast,
      curve: Curves.easeOutCubic,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardTheme.color,
          borderRadius: borderRadius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: widget.compact
                    ? (isDark ? 0.08 : 0.025)
                    : (isDark ? 0.2 : 0.05),
              ),
              blurRadius: widget.compact ? 4 : 10,
              offset: Offset(0, widget.compact ? 2 : 4),
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
                child: widget.compact
                    ? _buildCoverBackdrop()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 1. Cover Image (Expanded)
                          Expanded(flex: 3, child: _buildFullCover()),

                          // 2. Info Content
                          Expanded(
                            flex: 2,
                            child: widget.searchResult
                                ? _buildSearchInfo()
                                : Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        // Level 2: Category/Tag (Orange, Small) - ABOVE Title
                                        _buildMetaRow(),

                                        const SizedBox(height: 4),

                                        // Level 1: Title (Black, Bold, Large)
                                        Expanded(
                                          child: Text(
                                            widget.book.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium
                                                ?.copyWith(
                                                  height: 1.2,
                                                  fontSize: 14,
                                                ),
                                          ),
                                        ),

                                        // Level 3: Author (Grey, Secondary)
                                        if (widget.book.author != null &&
                                            widget.book.author!.isNotEmpty)
                                          Text(
                                            widget.book.author!,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(fontSize: 11),
                                          ),

                                        const SizedBox(height: 8),

                                        // Level 3: Bottom row (Stars/Size)
                                        _buildBottomRow(),
                                      ],
                                    ),
                                  ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
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
            top: 6,
            left: 6,
            right: 6,
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
    // 0.7 宽高比（见 heightFor）定。
    return LayoutBuilder(
      builder: (context, constraints) {
        final cacheWidth = coverCacheWidth(constraints.maxWidth, context);
        final cacheHeight = coverCacheHeight(
          BookCoverBackdrop.heightFor(constraints.maxWidth),
          context,
        );
        return CachedNetworkImage(
          imageUrl: widget.book.cover!,
          memCacheWidth: cacheWidth,
          memCacheHeight: cacheHeight,
          fadeInDuration: const Duration(milliseconds: 300),
          fadeOutDuration: const Duration(milliseconds: 100),
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
                imageUrl: widget.book.cover!,
                fit: BoxFit.cover,
                memCacheWidth: cacheWidth,
                fadeInDuration: const Duration(milliseconds: 300),
                fadeOutDuration: const Duration(milliseconds: 100),
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
            if (widget.searchResult && (hasScore || hasMeta))
              Positioned(
                right: 8,
                bottom: 8,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (hasScore) _buildCoverLabel(score, rating: true),
                    if (hasScore && hasMeta) const SizedBox(height: 4),
                    if (hasMeta) _buildCoverLabel(meta),
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
                color: Color(0xFFFFD76A),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2.5),
      decoration: BoxDecoration(
        // Quiet translucent charcoal instead of the saturated blue: white
        // text stays legible on any cover and the badge stops shouting.
        color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.52),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.library_books_rounded,
            size: 11,
            color: Colors.white.withValues(alpha: 0.9),
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
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
        if (hasTagExtra)
          Text(
            hasTag ? '• ${widget.book.tagExtra}' : widget.book.tagExtra!,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10),
          ),
      ],
    );
  }

  /// Build the bottom row (score + meta)
  Widget _buildBottomRow() {
    final hasScore = widget.book.score != null && widget.book.score!.isNotEmpty;
    final hasMeta = widget.book.meta != null && widget.book.meta!.isNotEmpty;

    if (!hasScore && !hasMeta) {
      // Show nothing if no data available
      return const SizedBox.shrink();
    }

    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (hasScore) ...[
          Icon(Icons.star_rounded, size: 14, color: cs.secondary),
          const SizedBox(width: 4),
          Text(
            widget.book.score!,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: cs.onSurface,
            ),
          ),
        ],
        const Spacer(),
        if (hasMeta)
          Text(
            widget.book.meta!,
            style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
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
