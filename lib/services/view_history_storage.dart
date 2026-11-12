import 'package:hive_flutter/hive_flutter.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../utils/diagnostics.dart';
import 'hive_service.dart';

/// 浏览历史（本地实现）——官网站内的"浏览历史"只记站内书，这里
/// 同样只记站内 [Book]：每次打开详情页都置顶一条（与网站行为一致），
/// 按 bookId 去重，超出 [maxEntries] 淘汰最旧的。
///
/// 存储：Hive `view_history` box，键 `book-<id>`，值为 Book.toJson()
/// 加 `viewedAt` 时间戳——重开详情时 [Book.fromJson] 能无损重建路由
/// 参数。只在本机记录，不上传任何服务器。
class ViewHistoryStore {
  /// 上限：足够一个月的浏览量，同时避免 box 无限膨胀。
  static const int maxEntries = 200;

  /// 记一次浏览。任何失败（box 未开、磁盘问题）都静默记入诊断——
  /// 浏览历史是锦上添花的功能，绝不能影响打开详情页本身。
  static void add(Book book) {
    try {
      final box = HiveService.viewHistoryBox;
      box.put('book-${book.id}', {
        ...book.toJson(),
        'viewedAt': DateTime.now().toIso8601String(),
      });
      _trimOldest(box);
    } catch (error) {
      logIgnored('view_history', error);
    }
  }

  /// 按最近浏览时间倒序返回全部条目（book + viewedAt）。
  static List<({Book book, DateTime viewedAt})> entries() {
    try {
      final box = HiveService.viewHistoryBox;
      final result = <({Book book, DateTime viewedAt})>[];
      for (final value in box.values) {
        if (value is! Map) continue;
        final map = Map<String, dynamic>.from(value);
        final viewedAt = DateTime.tryParse(map['viewedAt']?.toString() ?? '');
        map.remove('viewedAt');
        final book = Book.fromJson(map);
        if (viewedAt == null || book.id == 0) continue;
        result.add((book: book, viewedAt: viewedAt));
      }
      result.sort((a, b) => b.viewedAt.compareTo(a.viewedAt));
      return result;
    } catch (error) {
      logIgnored('view_history', error);
      return const [];
    }
  }

  /// 清空全部浏览历史。
  static Future<void> clear() async {
    try {
      await HiveService.viewHistoryBox.clear();
    } catch (error) {
      logIgnored('view_history', error);
    }
  }

  static void _trimOldest(Box box) {
    if (box.length <= maxEntries) return;
    // (key, viewedAt) 对，按时间升序删除最旧的，直到回到上限。
    final pairs = <(dynamic, DateTime)>[];
    for (final key in box.keys) {
      final value = box.get(key);
      if (value is! Map) continue;
      final viewedAt =
          DateTime.tryParse(value['viewedAt']?.toString() ?? '');
      pairs.add((key, viewedAt ?? DateTime.fromMillisecondsSinceEpoch(0)));
    }
    pairs.sort((a, b) => a.$2.compareTo(b.$2));
    final excess = box.length - maxEntries;
    for (var i = 0; i < excess && i < pairs.length; i++) {
      box.delete(pairs[i].$1);
    }
  }
}
