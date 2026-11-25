// Reading progress for the in-app local reader, persisted in Hive.
//
// foliate-js also keeps the position in the WebView's localStorage,
// but that is wiped when the user clears the WebView cache (and it
// never leaves this device's WebView data). The position therefore
// also lives here, keyed by the download task id (== the book id), so
// reopening a book restores where the user left off even after a
// cache clear. One JSON blob in the settings box, same pattern as
// `shelf_categories_v1`: small map, whole-blob rewrite, a failed
// write never breaks reading.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'hive_service.dart';

class ReaderProgressStore {
  static const String _key = 'reader_progress_v1';

  /// At most one Hive write per book per [minInterval]: `relocate`
  /// fires on every page turn, and a write per turn is pure churn.
  static const Duration minInterval = Duration(seconds: 2);

  static final Map<String, DateTime> _lastWrite = <String, DateTime>{};

  /// Saved CFI for [bookKey], or null when the book was never read
  /// (or the stored entry is unreadable).
  static String? readCfi(String bookKey) {
    try {
      final raw = HiveService.settingsBox.get(_key);
      if (raw is! String) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final entry = map[bookKey];
      if (entry is Map<String, dynamic>) {
        final cfi = entry['cfi'];
        return cfi is String && cfi.isNotEmpty ? cfi : null;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Save the position. Throttled: calls sooner than [minInterval]
  /// after the last write for the same book are dropped (the next
  /// page turn saves it). A failed write is swallowed — progress
  /// must never break reading.
  static Future<void> save(
    String bookKey,
    String cfi,
    double fraction, {
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final last = _lastWrite[bookKey];
    if (last != null && at.difference(last) < minInterval) return;
    _lastWrite[bookKey] = at;
    try {
      final box = HiveService.settingsBox;
      final raw = box.get(_key);
      final map = raw is String
          ? (jsonDecode(raw) as Map<String, dynamic>)
          : <String, dynamic>{};
      map[bookKey] = <String, dynamic>{
        'cfi': cfi,
        'fraction': fraction,
        'updatedAt': at.millisecondsSinceEpoch,
      };
      await box.put(_key, jsonEncode(map));
    } catch (_) {
      // Progress is best-effort; the reader keeps working.
    }
  }

  /// Drop the saved position for one book (e.g. after the book is
  /// deleted). A missing entry is a no-op.
  static Future<void> clear(String bookKey) async {
    try {
      final box = HiveService.settingsBox;
      final raw = box.get(_key);
      if (raw is! String) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map.remove(bookKey) == null) return;
      await box.put(_key, jsonEncode(map));
    } catch (_) {
      // Best-effort, same as save.
    }
  }

  @visibleForTesting
  static void resetThrottleForTest() => _lastWrite.clear();
}
