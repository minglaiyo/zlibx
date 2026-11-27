/// Completed tab of the downloads screen (P1-4 split of
/// local_downloads_screen.dart): the category filter bar + the
/// date-grouped list.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/shelf_categories_provider.dart';
import '../../screens/favorites/widgets/shelf_chip.dart';
import 'download_list.dart';

/// 已完成 Tab：分类筛选条 + 列表。任务 id 就是 bookId（历史条目按
/// bookId 存），分类归属用 `download:<bookId>` 键写进书架分类的
/// assignments 表。
class CompletedDownloadsTab extends ConsumerWidget {
  const CompletedDownloadsTab({
    required this.taskIds,
    required this.completedDates,
    required this.filter,
    required this.onFilterChanged,
  });

  final List<String> taskIds;

  /// Download stamp per completed id (from the list structure):
  /// the list groups by date from this map.
  final Map<String, DateTime?> completedDates;
  final String? filter;
  final ValueChanged<String?> onFilterChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context)!;
    final categories = ref.watch(shelfCategoriesProvider);
    final visible = taskIds.where((id) {
      final assigned = categories.assignments['download:$id'];
      if (filter == kShelfUncategorizedId) return assigned == null;
      if (filter != null) return assigned == filter;
      return true;
    }).toList();

    return Column(
      children: [
        _CompletedCategoryBar(
          taskIds: taskIds,
          selected: filter,
          onSelected: onFilterChanged,
        ),
        Expanded(
          child: DownloadList(
            taskIds: visible,
            groupDates: completedDates,
            emptyIcon: filter == null
                ? Icons.check_circle_outline_rounded
                : Icons.search_off_rounded,
            emptyTitle: filter == null
                ? l.noCompletedDownloads
                : l.shelfNoMatches,
            emptyMessage: filter == null
                ? l.downloadedBooksHere
                : l.shelfTryOtherFilter,
          ),
        ),
      ],
    );
  }
}

/// 分类筛选 chips：全部 / 未分类 / 各分类 + 计数。分类的新建与改名
/// 仍在书架的「管理分类」里，这里只消费同一棵树。
class _CompletedCategoryBar extends ConsumerWidget {
  const _CompletedCategoryBar({
    required this.taskIds,
    required this.selected,
    required this.onSelected,
  });

  final List<String> taskIds;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context)!;
    final categories = ref.watch(shelfCategoriesProvider);
    String? assignedFor(String id) => categories.assignments['download:$id'];

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Center(
              child: ShelfChip(
                label: '${l.shelfAllCategories} ${taskIds.length}',
                selected: selected == null,
                dense: true,
                onSelected: () => onSelected(null),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Center(
              child: ShelfChip(
                label:
                    '${l.shelfUncategorized} '
                    '${taskIds.where((id) => assignedFor(id) == null).length}',
                selected: selected == kShelfUncategorizedId,
                dense: true,
                onSelected: () => onSelected(kShelfUncategorizedId),
              ),
            ),
          ),
          for (final category in categories.categories)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Center(
                child: ShelfChip(
                  label:
                      '${category.name} '
                      '${taskIds.where((id) => assignedFor(id) == category.id).length}',
                  selected: selected == category.id,
                  dense: true,
                  onSelected: () => onSelected(category.id),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
