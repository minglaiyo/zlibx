import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/cover_cache.dart';
import '../../../widgets/cover_placeholder.dart';


/// One article search hit: cover + title + author + meta line. The
/// layout mirrors [FullTextHitTile] minus the matching-passage
/// snippet (the `/s/` article page carries none).
///
/// Removed articles (`deleted` 1/5/9 on the site) are greyed and
/// carry the 已移除 / 版权下架 chip — same labels and semantics as
/// the full-text tile; they stay tappable (site behaviour: the
/// detail page is still reachable).
class ArticleTile extends StatelessWidget {
  final Article article;
  final AppLocalizations l10n;
  final VoidCallback? onTap;

  const ArticleTile({
    super.key,
    required this.article,
    required this.l10n,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final metaParts = <String>[
      if (article.year != null && article.year != 0) '${article.year}',
      if (article.language != null && article.language!.isNotEmpty)
        article.language!,
      if (article.extension != null && article.extension!.isNotEmpty)
        article.extension!.toUpperCase(),
      if (article.filesizeString != null && article.filesizeString!.isNotEmpty)
        article.filesizeString!,
    ];
    final removedLabel = article.unavailableReason == 'copyright'
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
                opacity: article.removed ? 0.55 : 1,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 48,
                        height: 68,
                        child:
                            article.cover != null && article.cover!.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: article.cover!,
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
                            article.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          if (article.author != null &&
                              article.author!.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              article.author!,
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
              if (article.removed) ...[
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
