import 'package:flutter/foundation.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../utils/app_log.dart';
import 'hive_service.dart';

/// 首页随机推荐的"上一批"持久缓存（用户 2026-11-20 定）。
///
/// 每次真正返回给首页的那批 50 本（[Book] 形态，`toJson` 无损往返）
/// 落进 Settings 盒，按账号分键；app 重开后的第一次构建直接端出这批
/// ——零请求零转圈——同时后台滚新的一批，供下拉刷新秒出。刷新路径
/// 不吃缓存（见 home_feed_provider 的会话旗标），所以"刷新内容不变"
/// 的老毛病不会回归。
///
/// 键按账号隔离（`random_feed_batch_<账号id>`，未登录为 anon）：缓存
/// 的批次服务的是抽样结果，换号后各自的疲劳名单与收藏不同，不互串。
/// 读写全程 best-effort：盒没开/脏数据都读成空、写失败只记日志——
/// 首页不该为一份缓存挂掉。
class RandomFeedCache {
  /// Settings 盒里的键前缀（测试清理按前缀扫）。
  @visibleForTesting
  static const String keyPrefix = 'random_feed_batch_';

  /// 条目 TTL（审查 v2 P3）：与热门/最新缓存同一周——超过一周的批次
  /// 过期。旧形态（裸 List）视为有效。
  static const Duration ttl = Duration(days: 7);

  /// 上次展示的那批书；没有/损坏/过期/盒没开都返回 null，绝不抛。
  static List<Book>? readSync(String? userId) {
    try {
      final raw = HiveService.settingsBox.get(_key(userId));
      if (raw is Map) {
        final fetchedAt = raw['fetchedAt'];
        if (fetchedAt is int &&
            DateTime.now().millisecondsSinceEpoch - fetchedAt >=
                ttl.inMilliseconds) {
          return null;
        }
        final books = raw['books'];
        if (books is! List || books.isEmpty) return null;
        return [
          for (final item in books)
            Book.fromJson(Map<String, dynamic>.from(item as Map)),
        ];
      }
      if (raw is List && raw.isNotEmpty) {
        return [
          for (final item in raw)
            Book.fromJson(Map<String, dynamic>.from(item as Map)),
        ];
      }
      return null;
    } on Object {
      AppLog.report(
        '[random-feed] cannot read cached batch',
        tag: 'random_feed_cache',
      );
      return null;
    }
  }

  /// 记下这批要展示的书（整批覆盖写，带时间戳）。空批不写——把上一
  /// 批抹掉只会让下次启动多转一圈圈。
  static Future<void> persist(String? userId, List<Book> books) async {
    if (books.isEmpty) return;
    try {
      await HiveService.settingsBox.put(_key(userId), {
        'fetchedAt': DateTime.now().millisecondsSinceEpoch,
        'books': [for (final b in books) b.toJson()],
      });
    } on Object {
      AppLog.report(
        '[random-feed] cannot persist cached batch',
        tag: 'random_feed_cache',
      );
    }
  }

  /// 清掉所有账号的缓存（测试隔离用）。
  static Future<void> clearAll() async {
    try {
      final keys = HiveService.settingsBox.keys
          .where((k) => k is String && k.startsWith(keyPrefix))
          .toList();
      for (final key in keys) {
        await HiveService.settingsBox.delete(key);
      }
    } on Object {
      AppLog.report(
        '[random-feed] cannot clear cached batch',
        tag: 'random_feed_cache',
      );
    }
  }

  static String _key(String? userId) =>
      userId == null || userId.isEmpty
      ? '${keyPrefix}anon'
      : '$keyPrefix$userId';
}
