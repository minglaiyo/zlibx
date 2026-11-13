import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../models/display_book.dart';
import '../../../providers/books_provider.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../theme/app_metrics.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/app_snack.dart';
import '../../../utils/cover_cache.dart';
import '../../../widgets/loading_widget.dart';
import '../../../widgets/state_transition_switch.dart';
import 'book_3d_cover.dart';

class BookHeroSection extends ConsumerStatefulWidget {
  final DisplayBook book;
  final bool isFavorited;

  const BookHeroSection({
    super.key,
    required this.book,
    required this.isFavorited,
  });

  @override
  ConsumerState<BookHeroSection> createState() => _BookHeroSectionState();
}

class _BookHeroSectionState extends ConsumerState<BookHeroSection> {
  bool _saving = false;

  Future<void> _toggleFavorite() async {
    if (_saving) return;
    setState(() => _saving = true);
    final wasFavorited = widget.isFavorited;
    final bookId = widget.book.id;
    try {
      final notifier = ref.read(savedBooksProvider.notifier);
      final success = wasFavorited
          ? await notifier.unsaveBook(bookId)
          : await notifier.saveBook(
              bookId,
              // z 站详情页的 DisplayBook 背后就是完整 Book，乐观插入用它；
              // 非 z 站（Anna/LibGen）没有心形按钮，走不到这里，null 也无妨。
              book: widget.book.asZLibBook,
            );
      if (!mounted) return;
      if (success) ref.invalidate(isBookFavoritedProvider(bookId));
      final l10n = AppLocalizations.of(context)!;
      showAppSnack(
        context,
        !success
            ? l10n.favoriteFailed
            : wasFavorited
            ? l10n.favoriteRemoved
            : l10n.like,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final height = (MediaQuery.sizeOf(context).height * 0.54).clamp(
      340.0,
      420.0,
    );
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final collapsed =
            constraints.scrollOffset >= height - kToolbarHeight - 8;
        return SliverAppBar(
          expandedHeight: height,
          pinned: true,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          backgroundColor: !collapsed
              ? const Color(0xFF0D1723)
              : theme.scaffoldBackgroundColor,
          foregroundColor: collapsed ? cs.onSurface : Colors.white,
          leading: IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: AnimatedOpacity(
            opacity: collapsed ? 1 : 0,
            duration: AppMotion.fast,
            child: Text(
              widget.book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ),
          actions: [
            if (widget.book.isZLibrary)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: IconButton(
                  tooltip: widget.isFavorited ? l10n.removeFavorite : l10n.like,
                  onPressed: _saving ? null : _toggleFavorite,
                  icon: StateTransitionSwitch(
                    child: _saving
                        ? LoadingWidget.inline(
                            key: const ValueKey('saving'),
                            color: collapsed ? cs.primary : Colors.white,
                          )
                        : Icon(
                            widget.isFavorited
                                ? Icons.favorite
                                : Icons.favorite_border,
                            key: ValueKey(
                              widget.isFavorited ? 'favorited' : 'not-favorited',
                            ),
                            color: collapsed
                                ? (widget.isFavorited ? cs.primary : cs.onSurface)
                                : (widget.isFavorited
                                      ? const Color(0xFFFFA6B7)
                                      : Colors.white),
                            size: 22,
                          ),
                  ),
                ),
              ),
          ],
          flexibleSpace: FlexibleSpaceBar(
            background: _buildCover(context, height, animate: !collapsed),
          ),
        );
      },
    );
  }

  Widget _buildCover(
    BuildContext context,
    double height, {
    required bool animate,
  }) {
    Widget content({ImageProvider? image, bool loading = false}) {
      final theme = Theme.of(context);
      final background = theme.scaffoldBackgroundColor;
      return Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: const [Color(0xFF203A4B), Color(0xFF0D1723)],
              ),
            ),
          ),
          if (image != null)
            Opacity(
              opacity: 0.10,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Image(
                  image: image,
                  fit: BoxFit.cover,
                  excludeFromSemantics: true,
                ),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF0D1723).withValues(alpha: 0.20),
                  const Color(0xFF0D1723).withValues(alpha: 0.72),
                  background,
                ],
                stops: const [0, 0.82, 1],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(
              top: MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
              bottom: 16,
            ),
            child: Center(
              // 共享元素转场：来源卡片的封面（同 tag `cover-<id>`，
              // 见 BookCard.heroEnabled / ShelfGridItem）飞入这里。
              // 无封面的 3D 文字书也参与 Hero——来源侧无封面时不包
              // Hero，匹配不上就退化为普通转场，无害。
              child: Hero(
                tag: 'cover-${widget.book.id}',
                child: Book3DCover(
                  cover: image,
                  title: widget.book.title,
                  loading: loading,
                  animate:
                      animate && !MediaQuery.of(context).disableAnimations,
                  height:
                      (height -
                              MediaQuery.paddingOf(context).top -
                              kToolbarHeight -
                              58)
                          .clamp(170.0, 295.0),
                  // Rating lives only on the cover now: the interest /
                  // quality text the info section used to show as a tag.
                  badge: widget.book.ratingText == null
                      ? null
                      : _HeroRatingBadge(text: widget.book.ratingText!),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final cover = widget.book.cover;
    if (cover == null || cover.isEmpty) return content();
    // 要图与解码同宽：详情大图解码 400~900，covers100 原图放大会糊。
    final cacheWidth = ((height - kToolbarHeight) *
            0.7 *
            MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(400, 900);
    return CachedNetworkImage(
      imageUrl: coverUrlAtWidth(cover, cacheWidth),
      memCacheWidth: cacheWidth,
      imageBuilder: (context, image) => content(image: image),
      placeholder: (context, url) => content(loading: true),
      errorWidget: (context, url, error) => content(),
    );
  }
}

/// Rating pill on the hero cover: same dark pill + gold star as the
/// search card's cover label, slightly larger for the big cover.
class _HeroRatingBadge extends StatelessWidget {
  const _HeroRatingBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.star_rounded,
              size: 15,
              color: AppColors.ratingStar,
            ),
            const SizedBox(width: 3),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
