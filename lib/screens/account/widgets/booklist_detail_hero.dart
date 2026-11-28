import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../routes/app_routes.dart';
import '../../../theme/app_metrics.dart';
import '../../../utils/cover_cache.dart';

/// 折叠后钉在顶部的书单标题栏（原详情页内联的
/// SliverAppBar，P1-4 拆出；行为与文案不变）。
class BooklistDetailAppBar extends StatelessWidget {
  final String title;

  const BooklistDetailAppBar({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      surfaceTintColor: Colors.transparent,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// 视差大字头 + 白色圆角 sheet(作者 chip、玻璃胶囊、搜索排序行)。
/// 原 _Hero，P1-4 拆出并公开（仅改名与文件位置，行为与文案不变）。
class BooklistDetailHero extends StatelessWidget {
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

  const BooklistDetailHero({
    super.key,
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
                final dy = -(pixels.clamp(0.0, _heroHeight) * _parallaxFactor);
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
                            Shadow(color: Colors.black45, blurRadius: 10),
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
        cacheManager: coverCacheManager,
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
                      cacheManager: coverCacheManager,
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
                  cacheManager: coverCacheManager,
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
