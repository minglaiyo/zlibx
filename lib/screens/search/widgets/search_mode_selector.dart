import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../theme/app_metrics.dart';

/// The three search modes of the z站 search page. The enum lives here
/// (next to the switch that renders it); the screen owns the current
/// value and re-runs the query when it changes.
enum SearchMode { general, article, fulltext }

/// Three-segment mode switch for the search page (通用搜索 / 文章 /
/// 全文检索), shown only for the z站 source. Same sliding-highlight
/// segment idiom as the source selector: the selected segment gets
/// the primary-container pill, the rest stay quiet. Switching is
/// handed back via [onSwitch]; the screen owns the mode state and
/// re-runs the current query in the new mode.
class SearchModeSelector extends StatelessWidget {
  const SearchModeSelector({
    super.key,
    required this.l10n,
    required this.mode,
    required this.onSwitch,
  });

  final AppLocalizations l10n;
  final SearchMode mode;
  final ValueChanged<SearchMode> onSwitch;

  @override
  Widget build(BuildContext context) {
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
            Expanded(
              child: _ModeSegment(
                icon: Icons.search_rounded,
                label: l10n.generalSearch,
                selected: mode == SearchMode.general,
                onTap: () => onSwitch(SearchMode.general),
              ),
            ),
            Expanded(
              child: _ModeSegment(
                icon: Icons.article_rounded,
                label: l10n.articleSearch,
                selected: mode == SearchMode.article,
                onTap: () => onSwitch(SearchMode.article),
              ),
            ),
            Expanded(
              child: _ModeSegment(
                icon: Icons.find_in_page_rounded,
                label: l10n.fullTextSearch,
                selected: mode == SearchMode.fulltext,
                onTap: () => onSwitch(SearchMode.fulltext),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One segment of the mode selector (same shape as the source
/// selector's segment).
class _ModeSegment extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeSegment({
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
