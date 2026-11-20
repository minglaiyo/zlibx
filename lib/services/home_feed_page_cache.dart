import 'package:flutter/foundation.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../utils/app_log.dart';
import 'hive_service.dart';

/// 热门 / 最新两页的"上一批"持久缓存（2026-11-20，与随机推荐的启动
/// 缓存同一套定）。
///
/// 这两页的内容是全站的（不随账号个性化），键不分账号；跨镜像也没
/// 问题——同一站点数据库，书 id/标题/封面 CDN 全局一致。app 重开后的
/// 第一次第 1 页构建直接端出缓存（零转圈）；下拉刷新翻的是下一页
/// （屏幕层 1→2→…→9→1），不吃缓存，"刷新内容不变"的老毛病无从
/// 回归。
class HomeFeedPageCache {
  @visibleForTesting
  static const String popularKey = 'home_feed_page_popular';
  @visibleForTesting
  static const String recentKey = 'home_feed_page_recent';

  /// 条目 TTL（审查 v2 P3）：缓存只做"重开 app 直出"的垫场，网络一到
  /// 就被 SWR 换新——超过一周的批次宁可重新转圈，也别拿上周的热门糊
  /// 脸。旧形态（裸 List，无时间戳）视为有效：装包当天不该被误杀。
  static const Duration ttl = Duration(days: 7);

  /// 热门第 1 页的上一批；没有/损坏/过期/盒没开都返回 null，绝不抛。
  static List<Book>? popular() => _read(popularKey);

  /// 最新第 1 页的上一批。
  static List<Book>? recent() => _read(recentKey);

  static Future<void> savePopular(List<Book> books) =>
      _save(popularKey, books);

  static Future<void> saveRecent(List<Book> books) => _save(recentKey, books);

  static List<Book>? _read(String key) {
    try {
      return _booksOf(HiveService.settingsBox.get(key));
    } on Object {
      AppLog.report(
        '[home-feed] cannot read cached page',
        tag: 'home_feed_cache',
      );
      return null;
    }
  }

  /// 兼容两种形态：新 = `{'fetchedAt': ms, 'books': [...]}`（过期返回
  /// null）；旧 = 裸 List（无时间戳，视为有效）。
  static List<Book>? _booksOf(Object? raw) {
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
  }

  static Future<void> _save(String key, List<Book> books) async {
    // 空批不写——把上一批抹掉只会让下次启动多转一圈圈。
    if (books.isEmpty) return;
    try {
      await HiveService.settingsBox.put(key, {
        'fetchedAt': DateTime.now().millisecondsSinceEpoch,
        'books': [for (final b in books) b.toJson()],
      });
    } on Object {
      AppLog.report(
        '[home-feed] cannot persist cached page',
        tag: 'home_feed_cache',
      );
    }
  }

  /// 清掉两个键（测试隔离用）。
  static Future<void> clearAll() async {
    try {
      await HiveService.settingsBox.delete(popularKey);
      await HiveService.settingsBox.delete(recentKey);
    } on Object {
      AppLog.report(
        '[home-feed] cannot clear cached page',
        tag: 'home_feed_cache',
      );
    }
  }
}
