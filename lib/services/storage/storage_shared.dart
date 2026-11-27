import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../utils/app_log.dart';
import '../auth_storage.dart';
import '../hive_service.dart';

/// Helpers shared by the per-domain repositories split out of
/// `storage_service.dart` (P1-4). Moved verbatim; no behavior change.

/// The signed-in account's id, or null when signed out or when the
/// stored credentials cannot be read (secure storage unavailable).
/// A null here means "no account to scope to": reads see nothing and
/// writes refuse, rather than touching the shared legacy key.
Future<String?> currentAccountId() async {
  try {
    final userId = (await AuthStorage().getCredentials())['userId'];
    return (userId == null || userId.isEmpty) ? null : userId;
  } catch (error) {
    AppLog.report(
      '[storage] cannot resolve account id',
      tag: 'storage_service',
    );
    return null;
  }
}

/// 迁移键的统一读入口（审查 A1）：library 盒优先；盒还没开（首帧
/// 前窗口，迁移未跑）回退 settings——旧值还在那儿，同步读不空手。
Object? readMovedValue(String key) {
  final lib = HiveService.libraryBoxOrNull;
  if (lib != null) return lib.get(key);
  return HiveService.settingsBox.get(key);
}

/// 容量淘汰：按 fetchedAt 取最旧的一条（审查 v2 P3）。原先依赖
/// LinkedHashMap 首键（首次插入序），每轮刷新的条目位置不动，到上
/// 限时被逐出的恰恰是最热的条目。fetchedAt 缺失的条目视为最旧。
/// 两个调用点的 map 值类型不同（一个是 `Map<String,dynamic>` 的解码
/// 产物），这里按 dynamic 读。
void evictOldestEntry(Map<String, dynamic> merged) {
  String? oldestKey;
  var oldestAt = -1;
  merged.forEach((key, value) {
    final at = value is Map ? value['fetchedAt'] : null;
    final n = at is int ? at : 0;
    if (oldestKey == null || n < oldestAt) {
      oldestAt = n;
      oldestKey = key;
    }
  });
  if (oldestKey != null) merged.remove(oldestKey);
}

/// downloadedAt descending, nulls last (a record without a stamp
/// sorts after every stamped one).
int downloadedAtDesc(Book a, Book b) {
  final aTime = a.downloadedAt;
  final bTime = b.downloadedAt;
  if (aTime == null && bTime == null) return 0;
  if (aTime == null) return 1;
  if (bTime == null) return -1;
  return bTime.compareTo(aTime);
}
