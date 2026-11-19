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

  /// 热门第 1 页的上一批；没有/损坏/盒没开都返回 null，绝不抛。
  static List<Book>? popular() => _read(popularKey);

  /// 最新第 1 页的上一批。
  static List<Book>? recent() => _read(recentKey);

  static Future<void> savePopular(List<Book> books) =>
      _save(popularKey, books);

  static Future<void> saveRecent(List<Book> books) => _save(recentKey, books);

  static List<Book>? _read(String key) {
    try {
      final raw = HiveService.settingsBox.get(key);
      if (raw is! List || raw.isEmpty) return null;
      return [
        for (final item in raw)
          Book.fromJson(Map<String, dynamic>.from(item as Map)),
      ];
    } on Object {
      AppLog.report(
        '[home-feed] cannot read cached page',
        tag: 'home_feed_cache',
      );
      return null;
    }
  }

  static Future<void> _save(String key, List<Book> books) async {
    // 空批不写——把上一批抹掉只会让下次启动多转一圈圈。
    if (books.isEmpty) return;
    try {
      await HiveService.settingsBox.put(key, [
        for (final b in books) b.toJson(),
      ]);
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
