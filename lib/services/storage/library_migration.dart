import '../../utils/app_log.dart';
import '../../utils/json_utils.dart';
import '../hive_service.dart';
import 'storage_keys.dart';

/// settings → library one-time migration (review A1/A2), split out
/// of `storage_service.dart` (P1-4). Moved verbatim; no behavior
/// change, no key-name change.
class LibraryMigration {
  /// 一次性幂等迁移：业务键整体搬进 library，旧整表下载历史转逐条键
  /// （A2）。规则：
  /// - 标志在 → 直接返回；
  /// - library 已有同键不覆盖（首帧前经 [HiveService.libraryBoxAsync]
  ///   提前写入的新值优先于 settings 里的旧值）；
  /// - 旧历史 JSON 解不开 → 原值进 _corrupt 隔离键，不挡其他键；
  /// - 全部搬完才写标志；中途被杀下次启动重跑——搬移动作都是"缺才
  ///   补 + 删源"，重跑等价。
  static Future<void> migrateSettingsToLibrary() async {
    final settings = HiveService.settingsBox;
    if (settings.get(kLibraryMigratedFlag) == true) return;
    final library = await HiveService.libraryBoxAsync();
    bool isMovedKey(String key) =>
        key == kDownloadHistoryKey ||
        key == '${kDownloadHistoryKey}_corrupt' ||
        key == kDownloadedBookMetadataKey ||
        key == kBookDetailExtrasKey ||
        key.startsWith(kFavoritesKey) ||
        key.startsWith(kServerDownloadHistoryKey);
    for (final key in List<dynamic>.of(settings.keys)) {
      if (key is! String || !isMovedKey(key)) continue;
      if (!library.containsKey(key)) {
        await library.put(key, settings.get(key));
      }
      await settings.delete(key);
    }
    final legacyRaw = library.get(kDownloadHistoryKey);
    if (legacyRaw != null) {
      var converted = false;
      if (legacyRaw is String) {
        try {
          // 一次性迁移：旧版下载历史整个 blob 只有一条，量大时
          // 走后台 isolate（审查 P1-2）。
          final decoded = await decodeJsonMaybeIsolate(legacyRaw);
          if (decoded is Map) {
            final order = <String>[];
            for (final entry in decoded.entries) {
              if (entry.value is Map) {
                await library.put(
                  '$kDlPrefix${entry.key}',
                  Map<String, dynamic>.from(entry.value as Map),
                );
                order.add('${entry.key}');
              }
            }
            if (!library.containsKey(kDlOrderKey)) {
              await library.put(kDlOrderKey, order);
            }
            converted = true;
          }
        } catch (_) {
          converted = false;
        }
      }
      if (!converted) {
        AppLog.report(
          '[storage] ignoring corrupt download history entry',
          tag: 'storage_service',
        );
        if (!library.containsKey('${kDownloadHistoryKey}_corrupt')) {
          await library.put('${kDownloadHistoryKey}_corrupt', legacyRaw);
        }
      }
      await library.delete(kDownloadHistoryKey);
    }
    await settings.put(kLibraryMigratedFlag, true);
  }
}
