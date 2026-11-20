// Release-safe diagnostics for exceptions that are deliberately swallowed.
//
// Before this helper, ~28 `catch` blocks only called `debugPrint(...)`,
// which prints nothing useful in release builds: a swallowed failure left
// no trace at all. [logIgnored] keeps the same "do not crash, do not
// bother the user" behaviour but also records a bounded, in-memory trail
// that Settings / bug reports can dump.
//
// Privacy: only the tag, the exception TYPE and a timestamp are kept —
// never the message, URL or stack arguments, because exception text from
// the network layer can contain query strings, cookies or book links.
// Two narrow exceptions, both data-free:
// - the topmost `package:zlibx` frame (file:line) when a stack is passed
//   (only the global error hooks pass one), so a release crash can be
//   located without any user data;
// - the HTTP status code of a network error (e.g. `HTTP 503`).
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../services/hive_service.dart';


class Diagnostics {
  Diagnostics._();

  /// Upper bound on retained entries (oldest are dropped first).
  static const int maxEntries = 200;

  static final Queue<String> _entries = Queue<String>();

  // ── 持久化计数（审查 2026-11-21 5.3）────────────────────────────
  //
  // 环形轨迹只有 200 条且在内存里——"Dart 兜底何时可退役"（B1）靠它
  // 攒不出数据。计数器补这一层：`key → 次数`，内存累加，落 Hive
  // settings 盒。只存计数，无消息/URL/堆栈——与隐私约定一致。决策
  // 规则写在 CLAUDE.md 的 B1 条目：观察窗口内 `fallback:<tag>` 非零
  // = 兜底在救人（保留）；恒零 = 该模块的 Dart 解析器可退役。

  /// Hive settings 盒的存储键。
  static const String _countsKey = 'diagnostics_counts_v1';

  /// 内存计数（启动时从 Hive 恢复，之后累加）。
  static final Map<String, int> _counts = <String, int>{};
  static bool _countsLoaded = false;

  /// 计一个数。低频路径（回退）用 [countAndFlush] 立即落盘；高频路径
  /// （如 Rust 成功解析）用 [count]——每 20 次才刷一次盘。
  static void count(String key) {
    _ensureCountsLoaded();
    final next = (_counts[key] ?? 0) + 1;
    _counts[key] = next;
    if (next % 20 == 0) _persistCounts();
  }

  /// 计一个数并立即落盘（低频路径专用）。
  static void countAndFlush(String key) {
    _ensureCountsLoaded();
    _counts[key] = (_counts[key] ?? 0) + 1;
    _persistCounts();
  }

  static void _ensureCountsLoaded() {
    if (_countsLoaded) return;
    _countsLoaded = true;
    try {
      final saved = HiveService.settingsBox.get(_countsKey);
      if (saved is Map) {
        for (final entry in saved.entries) {
          final n = int.tryParse('${entry.value}');
          if (n != null && n > 0) _counts[entry.key.toString()] = n;
        }
      }
    } on Object catch (_) {
      // Hive 未初始化（部分测试环境）：内存计数照常，不落盘。
    }
  }

  static void _persistCounts() {
    try {
      HiveService.settingsBox.put(
        _countsKey,
        Map<String, dynamic>.of(_counts),
      );
    } on Object catch (_) {
      // Best-effort：落盘失败内存计数照常。
    }
  }

  /// Records one swallowed failure.
  ///
  /// [stack] is optional and only the global error hooks pass it: the
  /// topmost `package:zlibx` frame (file:line) is appended to the line,
  /// and a network error's HTTP status code is appended as well. The
  /// message and the rest of the stack are never recorded.
  static void record(String tag, Object error, {StackTrace? stack}) {
    final buffer = StringBuffer(
      '${DateTime.now().toIso8601String()} [$tag] ${error.runtimeType}',
    );
    final frame = _topZlibxFrame(stack);
    if (frame != null) buffer.write(' $frame');
    final status = _httpStatus(error);
    if (status != null) buffer.write(' HTTP $status');
    final line = buffer.toString();
    _entries.addLast(line);
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    if (kDebugMode) debugPrint(line);
  }

  /// The topmost `package:zlibx` frame in [stack], as
  /// `package:zlibx/<file>:<line>`, or null when there is none.
  /// File + line only — no function names, messages or user data.
  static String? _topZlibxFrame(StackTrace? stack) {
    if (stack == null) return null;
    for (final line in stack.toString().split('\n')) {
      final match = _zlibxFrameRe.firstMatch(line);
      if (match != null) {
        return 'package:zlibx/${match.group(1)}:${match.group(2)}';
      }
    }
    return null;
  }

  // Matches a Dart stack frame such as
  // `#0 Foo.bar (package:zlibx/services/foo.dart:123:45)` and captures
  // the file path (group 1) and the line number (group 2).
  static final _zlibxFrameRe = RegExp(r'package:zlibx/([^:)\s]+):(\d+)');

  /// The HTTP status code carried by a network error, if any.
  static int? _httpStatus(Object error) {
    if (error is DioException) return error.response?.statusCode;
    return null;
  }

  /// Snapshot, oldest first.
  static List<String> snapshot() => List<String>.unmodifiable(_entries);

  /// All entries as one text blob (for "copy diagnostics"), counters
  /// appended.
  static String dump() {
    final buffer = StringBuffer(_entries.join('\n'));
    if (_counts.isNotEmpty) {
      buffer..writeln()..writeln('-- counts --');
      for (final entry in _counts.entries) {
        buffer.writeln('${entry.key}: ${entry.value}');
      }
    }
    return buffer.toString();
  }

  @visibleForTesting
  static void clear() => _entries.clear();
}

/// Shorthand used by `catch` blocks that intentionally swallow [error].
/// The global error hooks pass [stack] so the ring log can record the
/// topmost `package:zlibx` frame; ordinary call sites omit it.
///
/// 同时累加 `fallback:<tag>` 持久化计数（低频路径，立即落盘）——B1 的
/// 退役决策数据源。
void logIgnored(String tag, Object error, {StackTrace? stack}) {
  Diagnostics.record(tag, error, stack: stack);
  Diagnostics.countAndFlush('fallback:$tag');
}
