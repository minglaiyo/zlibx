import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/search_suggestions_provider.dart';

/// 搜索建议面板（方案 D1）：输入非空且聚焦时列在搜索框正下方，
/// 纯本地匹配（最近搜索关键词 + 浏览历史书名/作者），点击建议
/// 回填并立即发起搜索。空列表时面板不渲染。
class SearchSuggestionsPanel extends StatelessWidget {
  const SearchSuggestionsPanel({
    super.key,
    required this.suggestions,
    required this.onSelect,
  });

  final List<SearchSuggestion> suggestions;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        elevation: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
              child: Text(
                l10n.searchSuggestions,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            for (final suggestion in suggestions)
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: Icon(
                  suggestion.fromHistory
                      ? Icons.menu_book_rounded
                      : Icons.history_rounded,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
                title: Text(
                  suggestion.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
                onTap: () => onSelect(suggestion.text),
              ),
          ],
        ),
      ),
    );
  }
}
