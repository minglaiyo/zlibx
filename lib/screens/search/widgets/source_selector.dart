import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/display_book.dart';
import '../../../theme/app_metrics.dart';

/// 从 search_screen 抽出的零状态段：搜索源三段选择器（滑动高亮）。
/// 切换经 [onSwitch] 回调交回搜索页。
class SearchSourceSelector extends StatelessWidget {
  const SearchSourceSelector({
    super.key,
    required this.l10n,
    required this.selected,
    required this.onSwitch,
  });

  final AppLocalizations l10n;
  final BookSource selected;
  final ValueChanged<BookSource> onSwitch;

  @override
  Widget build(BuildContext context) {
    final items = <BookSource>[
      BookSource.zlibrary,
      BookSource.annasArchive,
      BookSource.libgen,
    ];
    final icons = <BookSource, IconData>{
      BookSource.zlibrary: Icons.auto_stories_rounded,
      BookSource.annasArchive: Icons.public_rounded,
      BookSource.libgen: Icons.menu_book_rounded,
    };
    final labels = <BookSource, String>{
      BookSource.zlibrary: l10n.sourceZlibrary,
      BookSource.annasArchive: l10n.sourceAnnasArchive,
      BookSource.libgen: l10n.sourceLibgen,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            for (final source in items)
              Expanded(
                child: _SourceSegment(
                  icon: icons[source]!,
                  label: labels[source]!,
                  selected: selected == source,
                  onTap: () => onSwitch(source),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One segment of the sliding-highlight source selector.
class _SourceSegment extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SourceSegment({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: AppMotion.quick,
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: selected ? cs.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: selected
                          ? cs.onPrimaryContainer
                          : cs.onSurfaceVariant,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
