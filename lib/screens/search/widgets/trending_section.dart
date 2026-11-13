import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../services/open_library.dart';
import '../../../utils/cover_cache.dart';
import '../../../widgets/cover_placeholder.dart';

/// Open Library trending (ported from OpenlibExtended): a horizontal
/// cover strip. Tapping a cover searches its title on the current
/// source, exactly like upstream's trending page does.
///
/// 从 search_screen 抽出的零状态段；搜索行为经 [onSearch] 回调。
/// 排名角标与 12dp 圆角来自搜索页重构（Kimi），抽取时一并带入。
class SearchTrendingSection extends StatelessWidget {
  const SearchTrendingSection({
    super.key,
    required this.l10n,
    required this.books,
    required this.onSearch,
  });

  final AppLocalizations l10n;
  final List<TrendingBookData> books;
  final ValueChanged<String> onSearch;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.local_fire_department_outlined,
              size: 18,
              color: colors.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.trendingOnOpenLibrary,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: books.length,
            itemBuilder: (context, index) {
              final book = books[index];
              final title = book.title!.trim();
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: InkWell(
                  onTap: () => onSearch(title),
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 105,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: CachedNetworkImage(
                                imageUrl: coverUrlAtWidth(
                                  book.thumbnail ?? '',
                                  coverCacheWidth(105, context),
                                ),
                                height: 145,
                                width: 105,
                                fit: BoxFit.cover,
                                // 封面按显示尺寸解码，避免整图占内存。
                                memCacheWidth: coverCacheWidth(105, context),
                                memCacheHeight: coverCacheHeight(145, context),
                                placeholder: (context, url) =>
                                    const CoverPlaceholder.static(),
                                errorWidget: (context, url, error) =>
                                    const CoverPlaceholder.static(),
                              ),
                            ),
                            Positioned(
                              top: 6,
                              left: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '${index + 1}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
