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

class Diagnostics {
  Diagnostics._();

  /// Upper bound on retained entries (oldest are dropped first).
  static const int maxEntries = 200;

  static final Queue<String> _entries = Queue<String>();

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
  static final _zlibxFrameRe =
      RegExp(r'package:zlibx/([^:)\s]+):(\d+)');

  /// The HTTP status code carried by a network error, if any.
  static int? _httpStatus(Object error) {
    if (error is DioException) return error.response?.statusCode;
    return null;
  }

  /// Snapshot, oldest first.
  static List<String> snapshot() => List<String>.unmodifiable(_entries);

  /// All entries as one text blob (for "copy diagnostics").
  static String dump() => _entries.join('\n');

  @visibleForTesting
  static void clear() => _entries.clear();
}

/// Shorthand used by `catch` blocks that intentionally swallow [error].
/// The global error hooks pass [stack] so the ring log can record the
/// topmost `package:zlibx` frame; ordinary call sites omit it.
void logIgnored(String tag, Object error, {StackTrace? stack}) =>
    Diagnostics.record(tag, error, stack: stack);
