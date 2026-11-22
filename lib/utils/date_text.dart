/// 日期/时间展示文案的统一出口（此前分散在 downloads、
/// comment_card、my_comments、user_profile 四处重复实现）。
library;

import '../l10n/generated/app_localizations.dart';

/// 评论日期：接口给了相对时间（如 "3 days ago"）就优先用，
/// 否则回退到绝对日期串（可能为空串，调用方原样显示）。
String commentDateText(String dateRelative, String date) =>
    dateRelative.isNotEmpty ? dateRelative : date;

/// 下载完成时间：本地时区 yyyy-MM-dd。
String formatDownloadDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// 浏览历史条目时间：本地时区 MM-dd HH:mm（跨年再加年份——
/// 浏览历史通常很短，绝大多数条目都在本年内）。
String formatViewedAt(DateTime date, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final time =
      '${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}';
  final day =
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
  return date.year == ref.year ? '$day $time' : '${date.year}-$day $time';
}

/// Date bucket for one history/download row, from its download stamp.
/// The stamp is replayed as-is (no timezone conversion), so the group
/// label is computed from the stamp's own calendar date — it matches
/// the date the row itself shows. 本周 = this calendar week, Monday
/// first. Rows without a stamp go last.
String dateGroupLabel(AppLocalizations l10n, DateTime? stamp) {
  if (stamp == null) return l10n.historyGroupUnknownTime;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(stamp.year, stamp.month, stamp.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return l10n.historyGroupToday;
  if (diff == 1) return l10n.historyGroupYesterday;
  final monday = today.subtract(Duration(days: today.weekday - 1));
  if (!day.isBefore(monday)) return l10n.historyGroupThisWeek;
  return l10n.historyGroupEarlier;
}

/// Group a date-sorted list into consecutive (label, items) sections,
/// using [stampOf] to read each item's download stamp. The list must
/// already be sorted by date, so same-label rows are consecutive and
/// one pass suffices.
List<(String, List<T>)> groupByDateLabel<T>(
  List<T> items,
  AppLocalizations l10n,
  DateTime? Function(T item) stampOf,
) {
  final sections = <(String, List<T>)>[];
  for (final item in items) {
    final label = dateGroupLabel(l10n, stampOf(item));
    if (sections.isEmpty || sections.last.$1 != label) {
      sections.add((label, [item]));
    } else {
      sections.last.$2.add(item);
    }
  }
  return sections;
}
