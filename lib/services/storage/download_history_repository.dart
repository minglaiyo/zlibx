import 'package:hive/hive.dart';

import '../../utils/app_log.dart';
import '../hive_service.dart';
import 'storage_keys.dart';
import 'storage_write_queue.dart';

/// Local download history, split out of `storage_service.dart` (P1-4).
/// Moved verbatim; no behavior change, no key-name change.
class DownloadHistoryRepository {
  /// 插入序 id 列表；顺序表外的条目（手写/迁移残留）按键序补尾，不丢。
  List<String> _readDlOrder(Box<dynamic> box) {
    final ids = <String>[];
    final raw = box.get(kDlOrderKey);
    if (raw is List) {
      for (final item in raw) {
        ids.add('$item');
      }
    }
    for (final key in box.keys) {
      if (key is String && key.startsWith(kDlPrefix)) {
        final id = key.substring(kDlPrefix.length);
        if (!ids.contains(id)) ids.add(id);
      }
    }
    return ids;
  }

  /// Get all download history (insertion order — callers rely on the
  /// map iteration order, same contract as the old whole-table read).
  /// Tolerates a corrupt entry instead of crashing the caller:
  /// entries whose value is not a Map are dropped, so a malformed
  /// entry cannot break a later field read.
  Future<Map<String, dynamic>> getDownloadHistory() async {
    final box = await HiveService.libraryBoxAsync();
    final history = <String, dynamic>{};
    for (final id in _readDlOrder(box)) {
      final value = box.get('$kDlPrefix$id');
      if (value is Map) {
        history[id] = Map<String, dynamic>.from(value);
      } else if (value != null) {
        AppLog.report(
          '[storage] ignoring corrupt download history entry',
          tag: 'storage_service',
        );
      }
    }
    return history;
  }

  /// Get downloaded file path for a book
  Future<String?> getDownloadedFilePath(String bookId) async {
    final box = await HiveService.libraryBoxAsync();
    final value = box.get('$kDlPrefix$bookId');
    if (value is Map) return value['filePath'] as String?;
    return null;
  }

  /// Add book to download history
  /// Stores: {bookId: {title, author, filePath, cover, extension, downloadTime, source, customSubfolder, realPath}}
  /// [source] 是下载来源的枚举名（BookSource.name，#143）：zlibrary /
  /// annasArchive / libgen；旧条目没有这个键，读回来是 null。
  /// [customSubfolder] 是 #95 用户给这本书指定的子文件夹名；没指定
  /// 不存，读回来是 null。
  /// [realPath] 是发布时解析的真实文件路径（2026-11-26 孤儿行重链）：
  /// 清数据后 MediaStore 行失归属、存的 content:// URI 打不开时，
  /// 历史检查按它直接查文件。旧条目没有这个键，读回来是 null。
  Future<void> addToDownloadHistory(
    String bookId,
    String title,
    String? author,
    String filePath, {
    String? cover,
    String? extension,
    String? source,
    String? customSubfolder,
    String? realPath,
  }) async {
    await StorageWriteQueue.runSerialized(kDownloadHistoryKey, () async {
      final box = await HiveService.libraryBoxAsync();
      await box.put('$kDlPrefix$bookId', {
        'title': title,
        'author': author,
        'filePath': filePath,
        'cover': cover,
        'extension': extension,
        'downloadTime': DateTime.now().toIso8601String(),
        if (source != null) 'source': source,
        if (customSubfolder != null) 'customSubfolder': customSubfolder,
        if (realPath != null) 'realPath': realPath,
      });
      final order = _readDlOrder(box);
      if (!order.contains(bookId)) {
        order.add(bookId);
        await box.put(kDlOrderKey, order);
      }
    });
  }

  /// Relink a history entry to a new location after its stored
  /// content:// URI stopped opening (orphaned MediaStore row,
  /// 2026-11-26: clearing the app's data disowns the row,
  /// owner_package_name NULL, although the file itself is still on
  /// disk). Patches filePath + realPath in place, keeping every
  /// other field; no-op when the entry is gone. Serialized on the
  /// history key like the other history writes.
  Future<void> updateDownloadHistoryLocation(
    String bookId,
    String filePath, {
    String? realPath,
  }) async {
    await StorageWriteQueue.runSerialized(kDownloadHistoryKey, () async {
      final box = await HiveService.libraryBoxAsync();
      final value = box.get('$kDlPrefix$bookId');
      if (value is! Map) return;
      final entry = Map<String, dynamic>.from(value);
      entry['filePath'] = filePath;
      if (realPath != null) entry['realPath'] = realPath;
      await box.put('$kDlPrefix$bookId', entry);
    });
  }

  /// Remove book from download history
  Future<void> removeFromDownloadHistory(String bookId) async {
    await StorageWriteQueue.runSerialized(kDownloadHistoryKey, () async {
      final box = await HiveService.libraryBoxAsync();
      await box.delete('$kDlPrefix$bookId');
      final order = _readDlOrder(box);
      if (order.remove(bookId)) {
        await box.put(kDlOrderKey, order);
      }
    });
  }
}
