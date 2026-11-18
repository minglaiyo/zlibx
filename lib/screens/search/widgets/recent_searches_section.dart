import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'search_section_header.dart';


/// 从 search_screen 抽出的零状态段：近期搜索关键词 chips。点击即
/// 重新搜索（[onSearch]），删除单个 / 清空历史经回调交回搜索页。
class SearchRecentSearchesSection extends StatelessWidget {
  const SearchRecentSearchesSection({
    super.key,
    required this.l10n,
    required this.searches,
    required this.onSearch,
    required this.onRemove,
    required this.onClear,
  });

  final AppLocalizations l10n;
  final List<String> searches;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onRemove;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SearchSectionHeader(
          icon: Icons.history_rounded,
          title: l10n.searchHistoryTitle,
          trailing: TextButton.icon(
            onPressed: onClear,
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: Text(l10n.searchHistoryClear),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final keyword in searches)
              InputChip(
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(keyword, overflow: TextOverflow.ellipsis),
                ),
                onPressed: () => onSearch(keyword),
                onDeleted: () => onRemove(keyword),
                deleteButtonTooltipMessage: l10n.searchHistoryRemove,
                backgroundColor: cs.surfaceContainerLow,
                side: BorderSide(color: cs.outlineVariant),
              ),
          ],
        ),
      ],
    );
  }
}
