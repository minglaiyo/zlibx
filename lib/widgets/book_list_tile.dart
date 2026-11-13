import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/display_book.dart';
import '../utils/cover_cache.dart';
import 'cover_placeholder.dart';

/// Compact list tile for books.
class BookListTile extends StatelessWidget {
  final DisplayBook book;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showCover;
  final Widget? trailing;
  final String? extraLabel;

  const BookListTile({
    super.key,
    required this.book,
    this.onTap,
    this.onLongPress,
    this.showCover = false,
    this.trailing,
    this.extraLabel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: showCover
            ? ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 48,
                  height: 68,
                  child: book.cover != null && book.cover!.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: coverUrlAtWidth(
                            book.cover!,
                            coverCacheWidth(48, context),
                          ),
                          fit: BoxFit.cover,
                          memCacheWidth: coverCacheWidth(48, context),
                          memCacheHeight: coverCacheHeight(68, context),
                          placeholder: (context, url) =>
                              const CoverPlaceholder.static(),
                          errorWidget: (context, url, error) =>
                              const CoverPlaceholder.static(),
                        )
                      : const CoverPlaceholder.static(),
                ),
              )
            : Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.menu_book_rounded,
                  color: cs.primary,
                  size: 22,
                ),
              ),
        title: Text(
          book.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (book.author != null && book.author!.isNotEmpty)
              Text(
                book.author!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (extraLabel != null && extraLabel!.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                extraLabel!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: cs.primary),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                // Tag badge (format/category)
                if (book.tag != null && book.tag!.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: cs.secondary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      book.tag!,
                      style: TextStyle(
                        color: cs.secondary,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                if (book.tag != null && book.meta != null)
                  const SizedBox(width: 8),
                // Meta info
                if (book.meta != null)
                  Text(
                    book.meta!,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                  ),
                const Spacer(),
                // Year or other extra detail. (Rating is cover-only now:
                // the 48 px thumbnail here is too small for a badge, so
                // list tiles show no rating at all.)
                if (book.tagExtra != null && book.tagExtra!.isNotEmpty)
                  Text(
                    book.tagExtra!,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                  ),
              ],
            ),
          ],
        ),
        trailing:
            trailing ?? Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}
