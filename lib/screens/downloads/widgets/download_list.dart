/// The downloads list (P1-4 split of local_downloads_screen.dart):
/// the empty state, the flat list (ongoing tab) and the date-grouped
/// list (completed tab: today / yesterday / this week / earlier).
import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../utils/date_text.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/motion/motion.dart';
import 'download_item.dart';

class DownloadList extends StatelessWidget {
  const DownloadList({
    required this.taskIds,
    required this.emptyIcon,
    required this.emptyTitle,
    required this.emptyMessage,
    this.groupDates,
  });

  final List<String> taskIds;
  final IconData emptyIcon;
  final String emptyTitle;
  final String emptyMessage;

  /// Download stamp per task id: when given, the list groups by date
  /// (today / yesterday / this week / earlier). Null = flat list
  /// (the ongoing tab).
  final Map<String, DateTime?>? groupDates;

  @override
  Widget build(BuildContext context) {
    if (taskIds.isEmpty) {
      return EmptyState(
        icon: emptyIcon,
        title: emptyTitle,
        message: emptyMessage,
      );
    }
    // Bottom 124 = 28 gap + 96 floating-nav clearance, reserved
    // inside the list so items scroll behind the pill (like the
    // home grid).
    const padding = EdgeInsets.fromLTRB(16, 16, 16, 124);
    if (groupDates == null) {
      return ListView.separated(
        padding: padding,
        itemCount: taskIds.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, index) => MotionEntrance(
          index: index,
          child: DownloadItem(id: taskIds[index]),
        ),
      );
    }
    final l10n = AppLocalizations.of(context)!;
    final sections = groupByDateLabel<String>(
      taskIds,
      l10n,
      (id) => groupDates![id],
    );
    final items = <({String? header, String? id})>[];
    for (final section in sections) {
      items.add((header: section.$1, id: null));
      for (final id in section.$2) {
        items.add((header: null, id: id));
      }
    }
    return ListView.builder(
      padding: padding,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        if (item.header != null) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
            child: Text(
              item.header!,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: MotionEntrance(
            index: index,
            child: DownloadItem(id: item.id!),
          ),
        );
      },
    );
  }
}
