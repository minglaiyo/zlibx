/// 日期/时间展示文案的统一出口（此前分散在 downloads、
/// comment_card、my_comments、user_profile 四处重复实现）。
library;

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
  final day = '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
  return date.year == ref.year ? '$day $time' : '${date.year}-$day $time';
}
