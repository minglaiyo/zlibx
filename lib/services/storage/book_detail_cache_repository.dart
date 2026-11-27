import 'dart:convert';

import '../../utils/app_log.dart';
import '../../utils/diagnostics.dart';
import '../../utils/json_utils.dart';
import '../hive_service.dart';
import 'storage_keys.dart';
import 'storage_shared.dart';
import 'storage_write_queue.dart';

/// Book-detail caches, split out of `storage_service.dart` (P1-4).
/// Moved verbatim; no behavior change, no key-name change.
class BookDetailCacheRepository {
  // ===== Book-detail extras cache =====
  //
  // The detail page's volume/ISBN/IPFS/rating rows exist only in the
  // book's HTML page — hundreds of KB, previously fetched fresh on
  // EVERY open (the heaviest single request in the app on a slow
  // mirror). The parsed payload is 7 short strings; volume/ISBN/IPFS
  // are edition constants and only the two community ratings ever
  // change (with the eapi interestScore as the hero's fallback), so
  // they are cached per detail-page path and the provider skips the
  // HTML download entirely within its 7-day freshness window (same
  // TTL convention as BooklistHtmlCache).
  //
  // Key: the page's PATH (`/book/{hash}/{slug}.html`, query stripped
  // by the caller) — stable per edition. One global blob (not
  // account-scoped: bibliographic data does not depend on the
  // account), 2000-entry cap, corrupt reads empty, best-effort
  // writes. Values carry `fetchedAt` (ms since epoch) for the
  // provider's freshness check.

  /// The cached extras JSON for one detail-page path, or null. The
  /// map carries the seven parsed fields plus `fetchedAt`. A
  /// corrupt/blob-missing/box-not-open situation reads as null,
  /// never throws.
  Map<String, dynamic>? getBookDetailExtrasSync(String pagePath) {
    if (pagePath.isEmpty) return null;
    try {
      final raw = readMovedValue(kBookDetailExtrasKey);
      if (raw is! String || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final entry = decoded[pagePath];
      if (entry is! Map) return null;
      return Map<String, dynamic>.from(entry);
    } catch (error) {
      AppLog.report(
        '[storage] ignoring corrupt book-detail extras cache',
        tag: 'storage_service',
      );
      return null;
    }
  }

  /// Merge one book's freshly parsed extras into the cache (stamp
  /// `fetchedAt` = now, overwrite the key) and persist. Best-effort:
  /// a storage failure is logged, never thrown out of a page load.
  Future<void> mergeBookDetailExtras(
    String pagePath,
    Map<String, dynamic> fields,
  ) async {
    if (pagePath.isEmpty || fields.isEmpty) return;
    await StorageWriteQueue.runSerialized(kBookDetailExtrasKey, () async {
      try {
        final box = await HiveService.libraryBoxAsync();
        final merged = <String, dynamic>{};
        // 已有 blob 的解码单独容错：损坏时丢掉旧内容、用本条重建（修
        // 复性写入），而不是让整次保存失败。
        try {
          final raw = box.get(kBookDetailExtrasKey);
          if (raw is String && raw.isNotEmpty) {
            // 详情附加字段的 blob 随浏览增长，超阈值走后台 isolate
            // （审查 P1-2）；这里已在 async 闭包里。
            final decoded = await decodeJsonMaybeIsolate(raw);
            if (decoded is Map) {
              decoded.forEach((key, value) {
                if (value is Map) {
                  merged['$key'] = Map<String, dynamic>.from(value);
                }
              });
            }
          }
        } on Object catch (error) {
          // fall through to the repair write below — but leave a trail
          // (审查 v2 P2-2).
          logIgnored('book_detail_extras_read', error);
        }
        merged[pagePath] = {
          ...fields,
          'fetchedAt': DateTime.now().millisecondsSinceEpoch,
        };
        while (merged.length > kBookDetailExtrasCap) {
          evictOldestEntry(merged);
        }
        await box.put(kBookDetailExtrasKey, jsonEncode(merged));
      } catch (error) {
        AppLog.report(
          '[storage] book-detail extras cache save failed',
          tag: 'storage_service',
        );
      }
    });
  }

  // ===== 详情页 eapi 缓存（2026-11-21，实测驱动：短 hash 书每次打开
  // 都白付"注定失败的 fetch1 + 按标题解析"两个往返，重开同一本 0 缓存
  // 全重来——诊断包屏上计时实证 2.3s→5.0s）=====

  /// 取缓存的详情正文（新鲜返回 JSON，过期/缺失/坏形态返回 null）。
  /// best-effort：盒未开（首帧窗口/测试环境无 Hive）直接按未命中——
  /// Hive 未初始化时 openBox 的失败会以未处理异步错误漏出（try/catch
  /// 拦不住，实测），所以门禁必须打在调 openBox 之前。
  Future<Map<String, dynamic>?> getBookDetailCache(String bookId) async {
    if (!HiveService.isLibraryOpen) return null;
    try {
      final box = await HiveService.libraryBoxAsync();
      final raw = box.get('$kBookDetailCachePrefix$bookId');
      if (raw is! Map) return null;
      final fetchedAt = raw['fetchedAt'];
      if (fetchedAt is! int) return null;
      if (DateTime.now().millisecondsSinceEpoch - fetchedAt >=
          kBookDetailCacheTtl.inMilliseconds) {
        return null;
      }
      return Map<String, dynamic>.from(raw);
    } on Object catch (error) {
      logIgnored('book_detail_cache', error);
      return null;
    }
  }

  /// 写详情正文缓存。best-effort：盒未开直接跳过（理由同上）。
  Future<void> putBookDetailCache(
    String bookId,
    Map<String, dynamic> json,
  ) async {
    if (!HiveService.isLibraryOpen) return;
    try {
      final box = await HiveService.libraryBoxAsync();
      await box.put('$kBookDetailCachePrefix$bookId', {
        ...json,
        'fetchedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } on Object catch (error) {
      logIgnored('book_detail_cache', error);
    }
  }

  /// 取解析缓存；无映射返回 null（走原始流程）。best-effort：盒未开
  /// 直接按未命中（理由同 getBookDetailCache）。
  Future<String?> getResolvedEapiHash(String bookId, String hash) async {
    if (!HiveService.isLibraryOpen) return null;
    try {
      final box = await HiveService.libraryBoxAsync();
      final value = box.get('$kEapiHashResolvePrefix$bookId:$hash');
      return value is String && value.isNotEmpty ? value : null;
    } on Object catch (error) {
      logIgnored('book_detail_cache', error);
      return null;
    }
  }

  /// 存解析结果。resolved 与原 hash 相同（'same' 情形）不存。best-effort：
  /// 盒未开直接跳过（理由同 getBookDetailCache）。
  Future<void> putResolvedEapiHash(
    String bookId,
    String hash,
    String resolved,
  ) async {
    if (resolved.isEmpty || resolved == hash) return;
    if (!HiveService.isLibraryOpen) return;
    try {
      final box = await HiveService.libraryBoxAsync();
      await box.put('$kEapiHashResolvePrefix$bookId:$hash', resolved);
    } on Object catch (error) {
      logIgnored('book_detail_cache', error);
    }
  }
}
