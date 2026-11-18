import 'dart:async';

import 'package:flutter/foundation.dart';

import '../utils/app_log.dart';
import 'hive_service.dart';


/// 首页随机推荐的"已经给你看过"名单。
///
/// 随机分类推荐每次刷新都从某个分类里随机取一页，同一本书很容易在几
/// 次刷新里反复出现（分类页是固定的，重复纯属抽样本身）。这里记下最
/// 近展示过的书 id，下次抽样时先剔除名单里的，取不满一批再按"最久未
/// 看"的顺序补回来——所以去重永远不会把首页抽空。
///
/// 记的是**展示时刻**：预取（_prefetchNextBatch）只存一批备用，用户
/// 不一定刷新去取它；若在预取时就记账，那批书还没露面就被记成"看过
/// "，一旦账号切换或批次作废，名单里就白堵了一批书。
///
/// 内存里留一份镜像（[_ids]），Hive 只是它的持久化：写盘是异步的，同
/// 一批展示完紧接着就要拿它去筛下一批（预取就是"紧接着"），只认硬盘
/// 的话那份名单要到 put 落地才生效——竞态窗口不大，但一旦发生，预取
/// 的那批就会跟刚展示的那批撞书。
///
/// 全局一份、不分账号：这只是抽样疲劳控制，不是用户数据。换号后少看
/// 到几本前账号看过的书，比每个账号各存一份（各 400 条）更划算。
class RandomFeedHistory {
  /// Settings 盒里的键，值是 FIFO 顺序（最久在前）的书 id 字符串列表。
  @visibleForTesting
  static const String boxKey = 'random_shown_book_ids';

  /// 上限：400 本 ≈ 每次刷新 50 本 × 8 次。超过后丢最久没看的（列表
  /// 头部）。整读整写，400 个 id 也就 5KB 量级，上限只防长期膨胀。
  static const int cap = 400;

  static List<String>? _ids;
  static Future<void>? _pendingSave;

  /// 最近展示过的书 id，最久在前。第一次读时从盒里加载；盒没开、值
  /// 不是列表（测试里的脏数据 / 老版本残留）都读成空，绝不抛。
  static List<String> readSync() {
    return _ids ??= _load();
  }

  static List<String> _load() {
    try {
      final data = HiveService.settingsBox.get(boxKey);
      if (data is! List) return <String>[];
      return List<String>.from(data);
    } on Object {
      AppLog.report(
        '[random-feed] cannot read shown-book history',
        tag: 'random_feed_history',
      );
      return <String>[];
    }
  }

  /// 记下刚展示的一批书：追加到队尾，已在队里的先摘掉再追加（"最近
  /// 看过"永远排在最后），超出上限砍掉最久的。
  ///
  /// 同步改内存、异步落盘（best-effort，存失败只记日志——首页不该因
  /// 为一份疲劳名单写不下去而报错），落盘用 [flush] 等。
  static void recordShown(List<String> bookIds) {
    final fresh = bookIds.where((id) => id.isNotEmpty).toSet();
    if (fresh.isEmpty) return;
    final current = readSync();
    final merged = <String>[...current.where((id) => !fresh.contains(id))];
    merged.addAll(bookIds.where((id) => id.isNotEmpty));
    final trimmed = merged.length > cap
        ? merged.sublist(merged.length - cap)
        : merged;
    _ids = trimmed;
    _pendingSave = _persist(trimmed);
  }

  static Future<void> _persist(List<String> ids) async {
    try {
      await HiveService.settingsBox.put(boxKey, ids);
    } on Object {
      AppLog.report(
        '[random-feed] shown-book history save failed',
        tag: 'random_feed_history',
      );
    }
  }

  /// 清空名单（测试用；设置页将来要"重置推荐"也走这里）。
  static Future<void> clear() async {
    _ids = <String>[];
    try {
      await HiveService.settingsBox.delete(boxKey);
    } on Object {
      AppLog.report(
        '[random-feed] shown-book history clear failed',
        tag: 'random_feed_history',
      );
    }
  }

  /// 等最新一次落盘完成（测试用：断言硬盘内容前先 flush）。
  @visibleForTesting
  static Future<void> flush() => _pendingSave ?? Future<void>.value();

  /// 测试用：丢掉内存镜像，下一次读重新从盒里加载（用来验证冷启动
  /// 加载与坏值兜底）。
  @visibleForTesting
  static void resetCacheForTest() {
    _ids = null;
    _pendingSave = null;
  }
}
