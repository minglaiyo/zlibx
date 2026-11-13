import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';

/// 从 search_screen 抽出的零状态段：药丸形搜索框。筛选按钮带激活
/// 筛选数角标（[activeFilterCount]，仅站内源显示）；打开筛选面板、
/// 提交搜索、清空输入等行为经回调交回搜索页。
class SearchBarField extends StatelessWidget {
  const SearchBarField({
    super.key,
    required this.l10n,
    required this.controller,
    required this.isExternal,
    required this.activeFilterCount,
    required this.isQueryEmpty,
    this.hintText,
    required this.onSubmitted,
    required this.onFilterTap,
    required this.onClear,
  });

  final AppLocalizations l10n;
  final TextEditingController controller;
  final bool isExternal;
  final int activeFilterCount;
  final bool isQueryEmpty;

  /// Overrides the default hint (full-text mode shows the site's
  /// "search by phrase or words" hint); null keeps [l10n.searchForBooks].
  final String? hintText;
  final VoidCallback onSubmitted;
  final VoidCallback onFilterTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const radius = BorderRadius.all(Radius.circular(28));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: TextField(
        controller: controller,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => onSubmitted(),
        decoration: InputDecoration(
          hintText: hintText ?? l10n.searchForBooks,
          hintStyle: TextStyle(color: cs.onSurfaceVariant),
          prefixIcon: Icon(Icons.search_rounded, color: cs.onSurfaceVariant),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isExternal)
                Badge(
                  isLabelVisible: activeFilterCount > 0,
                  label: Text('$activeFilterCount'),
                  child: IconButton(
                    icon: Icon(
                      Icons.tune_rounded,
                      color: activeFilterCount > 0
                          ? cs.primary
                          : cs.onSurfaceVariant,
                    ),
                    onPressed: onFilterTap,
                  ),
                ),
              if (!isQueryEmpty)
                IconButton(
                  tooltip: l10n.clear,
                  icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant),
                  onPressed: onClear,
                ),
            ],
          ),
          filled: true,
          fillColor: cs.surfaceContainerHighest,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 14,
          ),
          border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
          enabledBorder:
              OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide(color: cs.primary, width: 1.4),
          ),
        ),
      ),
    );
  }
}
