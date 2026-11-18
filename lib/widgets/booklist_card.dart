import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/motion.dart';
import '../theme/app_metrics.dart';
import '../utils/booklist_colors.dart';
import '../utils/cover_cache.dart';

/// Rounded booklist cover with a soft shadow and a themed placeholder.
class BooklistCover extends StatelessWidget {
  final String url;
  final double width;
  final double height;

  const BooklistCover({
    super.key,
    required this.url,
    this.width = 72,
    this.height = 100,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: cs.primaryContainer,
      child: Center(
        child: Icon(
          Icons.collections_bookmark_rounded,
          size: width * 0.4,
          color: cs.onPrimaryContainer.withValues(alpha: 0.7),
        ),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: width,
          height: height,
          child: url.isEmpty
              ? placeholder
              : CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  // 封面按显示尺寸解码，避免整图占内存。
                  memCacheWidth: coverCacheWidth(width, context),
                  memCacheHeight: coverCacheHeight(height, context),
                  placeholder: (_, __) => placeholder,
                  errorWidget: (_, __, ___) => placeholder,
                ),
        ),
      ),
    );
  }
}

/// Small rounded "icon + text" tag (book count, views).
class BooklistMetaPill extends StatelessWidget {
  final IconData icon;
  final String text;

  const BooklistMetaPill({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: cs.onPrimaryContainer),
            const SizedBox(width: 4),
            Text(
              text,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: cs.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The booklist's book-count, views and comments pills, in one wrap.
class BooklistMetaPills extends StatelessWidget {
  final Booklist list;

  const BooklistMetaPills({super.key, required this.list});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final count = list.count;
    if (count == null && list.views.isEmpty && list.comments.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        if (count != null)
          BooklistMetaPill(
            icon: Icons.menu_book_rounded,
            text: l10n.booklistBookCount(count),
          ),
        if (list.views.isNotEmpty)
          BooklistMetaPill(icon: Icons.visibility_outlined, text: list.views),
        if (list.comments.isNotEmpty && list.comments != '0')
          BooklistMetaPill(icon: Icons.comment_outlined, text: list.comments),
      ],
    );
  }
}

/// Actions offered by a booklist card's "…" menu. The screen wires
/// only the actions it supports; the menu shows exactly those.
enum BooklistMenuAction {
  edit,
  changeColor,
  togglePublic,
  toggleFavorite,
  share,
  delete,
}

/// One booklist as a card: cover, name, creator, meta pills and a short
/// description. Used by the booklists screen. [onLongPress] deletes the
/// list (mine tab only); null disables it (discover tab).
///
/// A private list shows a lock next to its name; a favorited list a
/// filled heart. The list's color renders as a thin gradient strip on
/// the card's left edge. [onMenuSelected] wires the "…" menu (edit,
/// color, public/private, favorite, share, delete); null hides it.
class BooklistCard extends StatelessWidget {
  final Booklist list;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isMine;
  final ValueChanged<BooklistMenuAction>? onMenuSelected;

  const BooklistCard({
    super.key,
    required this.list,
    required this.onTap,
    this.onLongPress,
    this.isMine = false,
    this.onMenuSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final gradient = BooklistColors.gradientFor(list.color);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        // IntrinsicHeight bounds the Row height: the Row stretches its
        // children so the color strip fills the card, but a sliver child
        // gets unbounded height, and a stretch Row hands its flex child
        // a tight infinite height. That throws "BoxConstraints forces an
        // infinite height" in debug builds (the widget test runs debug;
        // release strips the assert, which is why the card renders fine
        // on device).
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (gradient != null)
                Container(
                  width: 5,
                  decoration: BoxDecoration(gradient: gradient),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      BooklistCover(url: list.coverUrl),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    list.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          height: 1.25,
                                        ),
                                  ),
                                ),
                                if (list.isPrivate) ...[
                                  const SizedBox(width: 6),
                                  Icon(
                                    Icons.lock_outline_rounded,
                                    size: 16,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ],
                                if (list.isFavorite) ...[
                                  const SizedBox(width: 6),
                                  Icon(
                                    Icons.favorite_rounded,
                                    size: 16,
                                    color: cs.primary,
                                  ),
                                ],
                              ],
                            ),
                            if (list.author.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(
                                    Icons.person_outline_rounded,
                                    size: 15,
                                    color: cs.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      list.author,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: cs.onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 8),
                            BooklistMetaPills(list: list),
                            if (list.description.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                list.description,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (onMenuSelected != null)
                        _BooklistMenuButton(
                          list: list,
                          isMine: isMine,
                          onSelected: onMenuSelected!,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "…" menu on a booklist card. Own lists get edit / color /
/// public-private / delete; any list gets favorite / share.
class _BooklistMenuButton extends StatelessWidget {
  final Booklist list;
  final bool isMine;
  final ValueChanged<BooklistMenuAction> onSelected;

  const _BooklistMenuButton({
    required this.list,
    required this.isMine,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<BooklistMenuAction>(
      icon: const Icon(Icons.more_vert_rounded),
      padding: EdgeInsets.zero,
      onSelected: onSelected,
      itemBuilder: (_) => [
        if (isMine)
          PopupMenuItem(
            value: BooklistMenuAction.edit,
            child: Text(l10n.booklistEdit),
          ),
        if (isMine)
          PopupMenuItem(
            value: BooklistMenuAction.changeColor,
            child: Text(l10n.booklistChangeColor),
          ),
        if (isMine)
          PopupMenuItem(
            value: BooklistMenuAction.togglePublic,
            child: Text(
              list.isPrivate
                  ? l10n.booklistMakePublic
                  : l10n.booklistMakePrivate,
            ),
          ),
        PopupMenuItem(
          value: BooklistMenuAction.toggleFavorite,
          child: Text(
            list.isFavorite ? l10n.unfavoriteBooklist : l10n.favoriteBooklist,
          ),
        ),
        PopupMenuItem(
          value: BooklistMenuAction.share,
          child: Text(l10n.shareBooklist),
        ),
        if (isMine)
          PopupMenuItem(
            value: BooklistMenuAction.delete,
            child: Text(l10n.delete),
          ),
      ],
    );
  }
}

/// One booklist as a grid tile: large cover, name, counts. Used by the
/// booklists screen's grid view. The color strip renders along the
/// tile's top edge; a private list shows a lock, a favorited list a
/// filled heart.
class BooklistGridCard extends StatelessWidget {
  final Booklist list;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isMine;
  final ValueChanged<BooklistMenuAction>? onMenuSelected;

  const BooklistGridCard({
    super.key,
    required this.list,
    required this.onTap,
    this.onLongPress,
    this.isMine = false,
    this.onMenuSelected,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final gradient = BooklistColors.gradientFor(list.color);
    final placeholder = ColoredBox(
      color: cs.primaryContainer,
      child: Center(
        child: Icon(
          Icons.collections_bookmark_rounded,
          size: 36,
          color: cs.onPrimaryContainer.withValues(alpha: 0.7),
        ),
      ),
    );
    return Card(
      margin: const EdgeInsets.all(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (gradient != null)
              Container(
                height: 4,
                decoration: BoxDecoration(gradient: gradient),
              ),
            AspectRatio(
              aspectRatio: 4 / 3,
              child: list.coverUrl.isEmpty
                  ? placeholder
                  : CachedNetworkImage(
                      imageUrl: list.coverUrl,
                      fit: BoxFit.cover,
                      memCacheWidth: coverCacheWidth(320, context),
                      memCacheHeight: coverCacheHeight(240, context),
                      placeholder: (_, __) => placeholder,
                      errorWidget: (_, __, ___) => placeholder,
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          list.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1.25,
                          ),
                        ),
                      ),
                      if (list.isPrivate)
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 15,
                          color: cs.onSurfaceVariant,
                        ),
                      if (list.isFavorite) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.favorite_rounded,
                          size: 15,
                          color: cs.primary,
                        ),
                      ],
                    ],
                  ),
                  if (list.count != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      l10n.booklistBookCount(list.count!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pulsing placeholder cards shown while the first page loads.
class BooklistSkeletonList extends StatefulWidget {
  final int count;

  const BooklistSkeletonList({super.key, this.count = 6});

  @override
  State<BooklistSkeletonList> createState() => _BooklistSkeletonListState();
}

class _BooklistSkeletonListState extends State<BooklistSkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.slowest,
  );

  @override
  void initState() {
    super.initState();
    if (!context.disableAnimations) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.disableAnimations && _controller.isAnimating) {
      _controller.stop();
    } else if (!context.disableAnimations && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final block = cs.onSurface.withValues(alpha: 0.08);
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: block,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1).animate(
        CurvedAnimation(parent: _controller, curve: MotionCurves.loop),
      ),
      child: Column(
        children: [
          for (var i = 0; i < widget.count; i++)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 72,
                      height: 100,
                      decoration: BoxDecoration(
                        color: block,
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          bar(double.infinity, 16),
                          const SizedBox(height: 8),
                          bar(120, 12),
                          const SizedBox(height: 14),
                          bar(90, 22),
                          const SizedBox(height: 12),
                          bar(double.infinity, 10),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
