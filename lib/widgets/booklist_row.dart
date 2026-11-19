import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../l10n/generated/app_localizations.dart';

/// One booklist row: cover thumb, name, author + book count + views,
/// optional description, chevron. Shared by the booklists screen and
/// the user profile page's booklists section.
///
/// [onLongPress] (关联书单页/发现 tab)：弹出与书籍同款的快捷操作
/// 面板（收藏/取消收藏/分享）；null 时长按无动作。
class BooklistRow extends StatelessWidget {
  final Booklist list;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const BooklistRow({
    super.key,
    required this.list,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final meta = [
      if (list.author.isNotEmpty) list.author,
      if (list.count != null) l10n.booklistBookCount(list.count!),
      if (list.views.isNotEmpty) list.views,
      if (list.comments.isNotEmpty && list.comments != '0') list.comments,
    ].join(' · ');
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 40,
          height: 56,
          child: list.coverUrl.isEmpty
              ? Container(
                  color: cs.primaryContainer,
                  child: Icon(
                    Icons.collections_bookmark_outlined,
                    color: cs.onPrimaryContainer,
                  ),
                )
              : Image.network(
                  list.coverUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    color: cs.primaryContainer,
                    child: Icon(
                      Icons.collections_bookmark_outlined,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                ),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              list.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (list.isPrivate) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.lock_outline_rounded,
              size: 15,
              color: cs.onSurfaceVariant,
            ),
          ],
          if (list.isFavorite) ...[
            const SizedBox(width: 4),
            Icon(Icons.favorite_rounded, size: 15, color: cs.primary),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (meta.isNotEmpty)
            Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          if (list.description.isNotEmpty)
            Text(
              list.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
        ],
      ),
      trailing: Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
