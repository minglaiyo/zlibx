// Downloads provider. The models live in download_task.dart, the tab
// structure in download_list_structure.dart, and the notifier's larger
// method clusters in the part files below. Dart cannot split one class
// body across parts, so each part declares a private mixin applied to
// DownloadNotifier; the public API stays on the notifier itself.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import '../services/http_client.dart';
import '../services/media_store.dart';
import '../services/pending_uri_writer.dart';
import '../services/resumable_downloader.dart';
import '../services/storage_service.dart';
import '../utils/app_log.dart';
import '../utils/diagnostics.dart';
import '../utils/file_utils.dart';
import 'download_slot_pool.dart';
import 'download_task.dart';
import 'zlibrary_provider.dart';

export 'download_task.dart';
export 'download_list_structure.dart';

part 'download_paths.dart';
part 'download_engine.dart';
part 'download_history.dart';

/// Shared state and small helpers for the DownloadNotifier mixins below.
/// `ref` is deliberately not cached in a `late final` field: ref.invalidate
/// re-runs build() on the same notifier instance.
abstract class _DownloadNotifierBase extends Notifier<List<DownloadTask>> {
  // Getters, not `late final` fields: ref.invalidate (account switch,
  // line change, logout) re-runs build() on the SAME notifier instance,
  // and a second assignment to a late final throws LateInitializationError
  // — the same trap that blanked the library screen in SavedBooksNotifier.
  ZLibraryApi get _api => ref.read(zlibraryApiProvider);
  StorageService get _storage => ref.read(storageServiceProvider);
  final Map<String, CancelToken> _cancelTokens = {};

  /// Throttle for progress ticks: Dio can fire dozens of callbacks per
  /// second, and every publish rebuilds the whole task list for every
  /// listener. A tick is published only when progress moved >= 1% or
  /// >= 200 ms passed since the last publish for that task. Terminal
  /// transitions (completed / error / cancelled) never go through here,
  /// so they are always published immediately.
  final Map<String, double> _lastPublishedProgress = {};
  final Map<String, DateTime> _lastPublishedAt = {};

  // Not final: build() re-assigns it on every invalidate (nothing reads
  // it today; kept for the startup-history signal).
  late Future<void> ready;

  /// Cancel a download
  void cancelDownload(String id) {
    final token = _cancelTokens[id];
    if (token == null) return;
    token.cancel();
    _updateTask(id, (t) => t.copyWith(status: DownloadStatus.cancelled));
    _clearProgressThrottle(id);
  }

  /// 请求暂停的下载轮次，按 CancelToken 记（不按任务 id）：engine 的
  /// 取消清理据此保留 .part（用户取消才删）。按令牌记，暂停后立即恢
  /// 复时旧轮次的 finally 不会误消费新轮次的暂停标记（O6）。请求本身
  /// 只置一次，engine 的 finally 会把它消费掉。方法在
  /// download_engine.dart 的 mixin 里（要调 startDownload）。
  final Set<CancelToken> _pauseRequested = {};

  void markMissingFile(String id) {
    _updateTask(
      id,
      (task) => task.copyWith(
        status: DownloadStatus.error,
        missingFile: true,
        error: 'File not found',
      ),
    );
  }

  /// Remove task and delete file
  Future<void> removeTask(String id) async {
    cancelDownload(id);
    // Idempotent delete: the task may already be gone (double tap on the
    // menu, history cleanup racing the UI). A missing task used to throw
    // and the caller showed "删除失败" for a perfectly successful delete.
    final matches = state.where((t) => t.id == id).toList();
    if (matches.isEmpty) return;
    final task = matches.first;

    // Delete file if exists (content:// URIs via ContentResolver).
    if (task.filePath != null) {
      await MediaStoreFiles.delete(task.filePath!);
    }

    // Remove from persistent storage
    await _storage.removeFromDownloadHistory(id);

    // Remove from state
    state = state.where((t) => t.id != id).toList();
    _clearProgressThrottle(id);
  }

  void _updateOrAddTask(DownloadTask task) {
    if (state.any((t) => t.id == task.id)) {
      state = state.map((t) => t.id == task.id ? task : t).toList();
    } else {
      state = [...state, task];
    }
  }

  /// Publishes one progress tick, throttled: a tick below 1.0 is only
  /// published when progress moved >= 1% since the last publish for
  /// this task, or >= 200 ms passed. A tick that reaches 1.0 always
  /// goes through immediately.
  void _updateProgress(String id, double progress) {
    // Late ticks from a cancelled/finished download must not republish
    // state: cancelDownload already flipped the status and cleared the
    // throttle maps, but chunks already queued in the stream keep
    // arriving for a moment.
    final token = _cancelTokens[id];
    if (token == null || token.isCancelled) return;
    // No firstOrNull dependency: avoid pulling in package:collection.
    DownloadTask? task;
    for (final t in state) {
      if (t.id == id) {
        task = t;
        break;
      }
    }
    if (task == null ||
        (task.status != DownloadStatus.downloading &&
            task.status != DownloadStatus.pending)) {
      return;
    }
    if (progress < 1.0) {
      final now = DateTime.now();
      final last = _lastPublishedProgress[id];
      final lastAt = _lastPublishedAt[id];
      if (last != null &&
          (progress - last).abs() < 0.01 &&
          lastAt != null &&
          now.difference(lastAt).inMilliseconds < 200) {
        return;
      }
      _lastPublishedProgress[id] = progress;
      _lastPublishedAt[id] = now;
    }
    _updateTask(id, (t) => t.copyWith(progress: progress));
  }

  /// Drops the throttle bookkeeping for [id]; called when a task leaves
  /// the downloading state so the maps stay bounded.
  void _clearProgressThrottle(String id) {
    _lastPublishedProgress.remove(id);
    _lastPublishedAt.remove(id);
  }

  void _updateTask(String id, DownloadTask Function(DownloadTask) updater) {
    state = state.map((t) {
      if (t.id == id) {
        return updater(t);
      }
      return t;
    }).toList();
  }
}

class DownloadNotifier extends _DownloadNotifierBase
    with _DownloadPathsMixin, _DownloadEngineMixin, _DownloadHistoryMixin {
  @override
  List<DownloadTask> build() {
    // Load persisted download history on initialization
    ready = _loadDownloadHistory();
    return [];
  }
}

final downloadProvider =
    NotifierProvider<DownloadNotifier, List<DownloadTask>>(
      DownloadNotifier.new,
    );

/// One download task by id. Watching this instead of [downloadProvider]
/// rebuilds a widget only when ITS task changes: [_updateTask] keeps the
/// identity of every untouched task, so `select` sees no change for them.
/// Use it in per-book widgets (action bars, list tiles) so one progress
/// tick no longer rebuilds every listener of the whole list.
final downloadTaskProvider =
    Provider.autoDispose.family<DownloadTask?, String>((ref, id) {
  return ref.watch(
    downloadProvider.select((tasks) {
      for (final t in tasks) {
        if (t.id == id) return t;
      }
      return null;
    }),
  );
});
