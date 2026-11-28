import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/cover_cache.dart';
import '../../../widgets/cover_placeholder.dart';

/// One full-text search hit: cover + title + author + meta line,
/// then the matching passage as a [RichText] whose `<em>` runs are
/// highlighted in the theme color. Mirrors [BookListTile]'s cover
/// block (same sizes, same placeholder, same mem-cache helpers).
///
/// Removed hits (`deleted` 1/5/9 on the site) are greyed and carry a
/// 已移除 / 版权下架 chip; they stay tappable to the detail page
/// (site behaviour) but the detail page hides the download button
/// (see [BookDetailArgs.unavailableReason]).
class FullTextHitTile extends StatelessWidget {
  final FullTextHit hit;
  final AppLocalizations l10n;
  final VoidCallback? onTap;

  const FullTextHitTile({
    super.key,
    required this.hit,
    required this.l10n,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final book = hit.book;
    final metaParts = <String>[
      if (book.year != null && book.year != 0) '${book.year}',
      if (book.language != null && book.language!.isNotEmpty) book.language!,
      if (book.extension != null && book.extension!.isNotEmpty)
        book.extension!.toUpperCase(),
      if (book.filesizeString != null && book.filesizeString!.isNotEmpty)
        book.filesizeString!,
    ];
    final removedLabel = hit.unavailableReason == 'copyright'
        ? l10n.copyrightRemoved
        : l10n.removedBook;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Opacity(
                opacity: hit.removed ? 0.55 : 1,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 48,
                        height: 68,
                        child: book.cover != null && book.cover!.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: book.cover!,
                                cacheManager: coverCacheManager,
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
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            book.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          if (book.author != null &&
                              book.author!.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              book.author!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                          if (metaParts.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              metaParts.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (hit.snippet.isNotEmpty) ...[
                const SizedBox(height: 10),
                Opacity(
                  opacity: hit.removed ? 0.55 : 1,
                  child: RichText(
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                      children: [
                        for (final part in hit.snippet)
                          TextSpan(
                            text: part.text,
                            style: part.highlighted
                                ? TextStyle(
                                    color: cs.primary,
                                    fontWeight: FontWeight.w600,
                                    backgroundColor: cs.primaryContainer,
                                  )
                                : null,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              if (hit.removed) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    removedLabel,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
