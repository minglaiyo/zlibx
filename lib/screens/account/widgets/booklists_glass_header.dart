/// Glass header for the booklists screen (P1-4 split of
/// booklists_screen.dart): the floating frosted-glass header (same style
/// as home) — back button + capsule search field + typo tabs, plus the
/// sort row on discover/favorite. Content scrolls underneath it.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/booklists_provider.dart';
import '../../providers/settings_provider.dart';
import '../../theme/app_metrics.dart';
import 'booklists_typo_tabs.dart';

class BooklistsGlassHeader extends ConsumerWidget {
  const BooklistsGlassHeader({
    super.key,
    required this.l10n,
    required this.tab,
    required this.order,
    required this.searchController,
    required this.onSearchSubmitted,
    required this.onClearSearch,
    required this.onSelectTab,
    required this.onPickSort,
  });

  final AppLocalizations l10n;
  final BooklistTab tab;
  final String order;
  final TextEditingController searchController;

  /// Submitted query (the controller's `search`).
  final ValueChanged<String> onSearchSubmitted;
  final VoidCallback onClearSearch;

  /// Tab tap: the screen switches the tab and animates the PageView.
  final ValueChanged<BooklistTab> onSelectTab;

  /// Sort button tap: the screen opens the sort dialog.
  final VoidCallback onPickSort;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blurEnabled = ref.watch(blurEnabledProvider);
    final cs = Theme.of(context).colorScheme;
    final topInset = MediaQuery.paddingOf(context).top;
    final header = Container(
      decoration: BoxDecoration(
        color: blurEnabled ? cs.surface.withValues(alpha: 0.65) : cs.surface,
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      padding: EdgeInsets.fromLTRB(0, topInset, 0, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: BackButton(),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: SizedBox(
              width: double.infinity,
              child: _BooklistsSearchBar(
                l10n: l10n,
                searchController: searchController,
                onSubmitted: onSearchSubmitted,
                onClearSearch: onClearSearch,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: BooklistsTypoTabs(
              active: tab,
              labels: {
                BooklistTab.mine: l10n.myBooklists,
                BooklistTab.discover: l10n.discoverBooklists,
                BooklistTab.favorite: l10n.booklistsFavoriteTab,
              },
              onSelect: onSelectTab,
            ),
          ),
          // 排序只在发现/收藏出现;视图切换被封面流取代,删。
          if (tab != BooklistTab.mine) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onPickSort,
                  icon: const Icon(Icons.swap_vert_rounded, size: 18),
                  label: Text(_sortLabel(l10n, order)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    if (!blurEnabled) return header;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: header,
      ),
    );
  }
}

/// The current sort order's label for the sort button.
String _sortLabel(AppLocalizations l10n, String order) {
  return switch (order) {
    'date_created' => l10n.booklistSortNewest,
    'date_updated' => l10n.booklistSortUpdated,
    _ => l10n.booklistSortPopular,
  };
}

// Capsule search field + soft shadow, matching the library page.
class _BooklistsSearchBar extends StatelessWidget {
  const _BooklistsSearchBar({
    required this.l10n,
    required this.searchController,
    required this.onSubmitted,
    required this.onClearSearch,
  });

  final AppLocalizations l10n;
  final TextEditingController searchController;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        boxShadow: AppShadows.elevated(Theme.of(context).brightness),
      ),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: searchController,
        builder: (context, value, _) => TextField(
          controller: searchController,
          textInputAction: TextInputAction.search,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            hintText: l10n.searchBooklists,
            // 用户定稿(2026-11-20):占位文字靠左,放大镜在最右;输入
            // 非空时清空钮并排出现在放大镜左侧。
            prefixIcon: null,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 10,
            ),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (value.text.isNotEmpty)
                  IconButton(
                    tooltip: l10n.clear,
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: onClearSearch,
                  ),
                const Icon(Icons.search_rounded),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
