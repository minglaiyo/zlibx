part of 'download_provider.dart';

/// The download execution cluster: startDownload plus the resumable
/// transport and its failure cleanup.
mixin _DownloadEngineMixin on _DownloadPathsMixin {
  /// S6: at most this many downloads run at once (the review suggests
  /// 2–3). A field, not a local: the pool must survive `ref.invalidate`
  /// re-running build() on the same notifier instance, and a queued
  /// download's wait must outlive the call that started it.
  final DownloadSlotPool _slotPool = DownloadSlotPool();

  /// 暂停：取消在途请求（网络层立即停），.part 保留，任务停在被暂停
  /// 的进度上。恢复走 [resumeDownload] → startDownload 的断点续传。
  void pauseDownload(String id) {
    final token = _cancelTokens[id];
    if (token == null) return;
    // Keyed by token, not id (O6): a pause-then-resume-then-pause
    // sequence must not let the old round's finally consume the new
    // round's pause flag and delete the partial as a "cancel".
    _pauseRequested.add(token);
    token.cancel();
    _updateTask(id, (t) => t.copyWith(status: DownloadStatus.paused));
    _clearProgressThrottle(id);
  }

  /// 恢复：重跑完整下载流程（startDownload 会从 .part 断点续传，
  /// pendingWriter/MediaStore 条目也会按已写字节恢复）。
  void resumeDownload(String id) {
    final matches = state.where((t) => t.id == id).toList();
    if (matches.isEmpty) return;
    final task = matches.first;
    if (task.status != DownloadStatus.paused) return;
    unawaited(startDownload(task.book, presetUrl: task.presetUrl));
  }

  /// Running download round per book id (O6). A resume issued while the
  /// previous round is still settling (stream exit, sink close, finally)
  /// must wait for it: otherwise the new round reads file.length() /
  /// bytesWritten before the old sink flushed, and appends at a stale
  /// offset, duplicating bytes into the book.
  final Map<String, Future<void>> _runningRounds = {};

  /// Start a download.
  ///
  /// 默认走 ZLibraryApi（用户自己账号查 URL + 下载）。
  /// [presetUrl] 传入时跳过 URL 获取，直接用此 URL 下文件 —
  /// 用于外部源（Anna's Archive / LibGen）解析出的直链。
  /// 不支持自定义请求头（S5）：dio 自动跟随重定向时会把自定义头
  /// 带到任意目标主机，这个口子不开。以前留过 LAN 传书的
  /// `presetHeaders`（`X-Olib-Token`），功能无调用方，已删除。
  ///
  /// Thin wrapper around [_runDownloadRound]: it records the round so
  /// a later call for the same book waits for this one to settle
  /// instead of racing it on the same .part / pending entry.
  Future<void> startDownload(
    Book book, {
    String? presetUrl,
  }) {
    final id = book.id.toString();
    final previous = _runningRounds[id];
    final round = _runDownloadRound(
      book,
      presetUrl: presetUrl,
      previous: previous,
    );
    _runningRounds[id] = round;
    // Drop the entry when this round settles. `then` with onError
    // (not whenComplete) so a round that threw does not surface its
    // error a second time here — the round's own future already
    // carries it to the caller.
    unawaited(
      round.then<void>(
        (_) => _dropRound(id, round),
        onError: (_) => _dropRound(id, round),
      ),
    );
    return round;
  }

  void _dropRound(String id, Future<void> round) {
    if (identical(_runningRounds[id], round)) _runningRounds.remove(id);
  }

  /// True when a round for [id] is currently downloading or queued.
  bool _isDownloadActive(String id) => state.any(
        (t) =>
            t.id == id &&
            (t.status == DownloadStatus.downloading ||
                t.status == DownloadStatus.pending),
      );

  Future<void> _runDownloadRound(
    Book book, {
    String? presetUrl,
    Future<void>? previous,
  }) async {
    final id = book.id.toString();

    // Fast path: a round is already running for this book.
    if (_isDownloadActive(id)) return;
    // Wait for the previous round to settle before touching the same
    // .part / pending entry (O6). A failed previous round must not
    // fail this one — the error status it left behind is what the
    // guard below reads.
    if (previous != null) {
      try {
        await previous;
      } catch (_) {
        // Previous round already recorded its own error status.
      }
    }
    // Re-check: another round may have started while we waited.
    if (_isDownloadActive(id)) return;

    // Add or update task to pending
    final cancelToken = CancelToken();
    _cancelTokens[id] = cancelToken;
    _updateOrAddTask(
      DownloadTask(
        id: id,
        book: book,
        status: DownloadStatus.pending,
        needsFreshLink: presetUrl != null,
        presetUrl: presetUrl,
      ),
    );

    // S6: wait for a free slot (FIFO). Callers fire this with
    // `unawaited`, so the wait never blocks the UI; the task shows as
    // pending while queued.
    await _slotPool.acquire();
    // Cancelled while queued: give the slot back and stop without
    // downloading. (The `finally` below never runs on this path, so
    // the release has to happen here.)
    if (cancelToken.isCancelled) {
      _slotPool.release();
      // 排队期间被暂停：任务已由 pauseDownload 置为 paused，.part 还
      // 没有开始写，无需清理；只要消费掉本轮的暂停标记。
      _pauseRequested.remove(cancelToken);
      return;
    }

    String? temporaryPath;
    // Pending MediaStore entry for this download (Android 10+ only).
    // Null = staging fallback (.part file + publish copy).
    PendingUriWriter? pendingWriter;
    try {
      // Downloads go to the app-specific external dir: no storage
      // permission is needed on any Android version.
      final finalPath =
          '${await _resolveSaveDir()}/${_buildSafeFileName(book)}';

      if (cancelToken.isCancelled) return;

      temporaryPath = '$finalPath.part';

      // Update to downloading. Keep the existing progress: a fresh
      // download starts at 0 (the task was created with progress 0), and
      // a resume continues from where it paused — resetting to 0 would
      // flash the bar back to zero on every resume (O13).
      _updateTask(
        id,
        (t) => t.copyWith(status: DownloadStatus.downloading),
      );

      // Write to a task-specific temporary file so cancellation never leaves
      // a partial book under its final name.
      final alreadyExists = await File(finalPath).exists();
      // Pending MediaStore entry (Android 10+): only when actually
      // downloading. An already-present file needs no writer — creating
      // one would publish an empty entry and record its URI instead of
      // the real file. Any failure here keeps the staging flow
      // (pendingWriter stays null).
      if (Platform.isAndroid && !alreadyExists) {
        pendingWriter = await PendingUriWriter.resume(
          savePath: temporaryPath,
        );
        if (pendingWriter != null &&
            !await MediaStoreFiles.exists(pendingWriter.uri)) {
          // The pending entry vanished (user deleted it in Files);
          // the sidecar is stale — drop it and start a fresh entry.
          await pendingWriter.discard();
          pendingWriter = null;
        }
        pendingWriter ??= await PendingUriWriter.create(
          displayName: _buildSafeFileName(book),
          mimeType: MediaStoreFiles.mimeTypeForExtension(book.extension),
          savePath: temporaryPath,
        );
      }
      // O1: start (or keep) the foreground service so the download
      // survives backgrounding; the notification shows progress.
      await DownloadForegroundService.start();
      if (!alreadyExists && presetUrl != null) {
        // presetUrl 路径（外部源解析链接）：直接 stream 到本地，
        // 用独立 Dio，不带 z站 cookie / auth，也不带任何自定义头 —
        // followRedirects 必须为 true：LibGen get.php 307 跳到 CDN
        // 文件，不跟随会把重定向响应本身存成文件；跟随时不带上层
        // 自定义头，所以跨主机跳转没有凭据外泄面（S5）。
        // receiveTimeout: null = 不限接收超时：大文件慢速网络不能被打断。
        // The Dio is a single-use instance for this one download:
        // close it in a finally so a failed or cancelled download
        // does not leak its HttpClient (O13).
        final dio = createDio(receiveTimeout: null);
        try {
          await _downloadResumable(
            dio,
            presetUrl,
            temporaryPath,
            onProgress: (received, total) {
              // `total` can be 0 (empty body / CDN without length): only a
              // positive total yields a valid fraction — 0/0 would push a
              // NaN into the state and straight into the progress bar.
              if (total > 0) {
                final progress = received / total;
                _updateProgress(id, progress);
                _notifyDownloadProgress(progress);
              }
            },
            cancelToken: cancelToken,
            pendingWriter: pendingWriter,
          );
        } finally {
          dio.close();
        }
      } else if (!alreadyExists) {
        // 默认路径：用户自己 z站 账号查 URL + 下载
        try {
          await _api.downloadBook(
            book.id.toString(),
            book.hash ?? '',
            temporaryPath,
            onProgress: (received, total) {
              // Same NaN guard as the preset branch above.
              if (total > 0) {
                final progress = received / total;
                _updateProgress(id, progress);
                _notifyDownloadProgress(progress);
              }
            },
            cancelToken: cancelToken,
            title: book.title,
            pendingWriter: pendingWriter,
          );
        } on DownloadLimitReachedException {
          rethrow;
        } catch (e) {
          // Z 站额度用尽的返回形态不稳定，失败后再查一次资料兜底识别
          if (!cancelToken.isCancelled && await _isOwnQuotaExhausted()) {
            throw DownloadLimitReachedException();
          }
          rethrow;
        }
      }

      if (cancelToken.isCancelled) return;
      if (identical(_cancelTokens[id], cancelToken)) _cancelTokens.remove(id);

      final completedAt = DateTime.now();
      int fileSize;

      // The final location, and where the history records it.
      var recordedPath = finalPath;
      if (pendingWriter != null) {
        // Flush the writer's buffer and publish the pending entry
        // (clear IS_PENDING): the book is already in Downloads/zlibx.
        await pendingWriter.flush();
        if (!await pendingWriter.finish()) {
          // Publishing failed (e.g. the entry was removed): the book
          // never reached Downloads — fail, don't record a dead URI.
          await pendingWriter.discard();
          pendingWriter = null;
          throw StateError(
            'could not publish the download into Downloads/zlibx',
          );
        }
        recordedPath = pendingWriter.uri;
        // After flush() the buffer is empty, so bytesWritten is the
        // total committed size — the file size for the task record.
        fileSize = pendingWriter.bytesWritten;
        pendingWriter = null;
      } else {
        if (await File(temporaryPath).exists()) {
          await File(temporaryPath).rename(finalPath);
        }
        fileSize = await File(finalPath).length();

        // Publish into the public Downloads/zlibx folder (MediaStore,
        // Android 10+). On failure keep the app-specific file and
        // report success with that location — the download itself
        // still counts.
        if (Platform.isAndroid) {
          final uri = await MediaStoreFiles.publishToDownloads(
            sourcePath: finalPath,
            displayName: _buildSafeFileName(book),
            mimeType: MediaStoreFiles.mimeTypeForExtension(book.extension),
          );
          if (uri != null) {
            recordedPath = uri;
            try {
              await File(finalPath).delete();
            } catch (e) {
              AppLog.report(
                'Could not remove staged download: $e',
                tag: 'download_provider',
              );
            }
          } else {
            AppLog.report(
              'MediaStore publish failed, keeping app-specific file',
              tag: 'download_provider',
            );
          }
        }
      }

      // Save to download history (with cover and extension for persistence)
      await _storage.addToDownloadHistory(
        book.id.toString(),
        book.title,
        book.author,
        recordedPath,
        cover: book.cover,
        extension: book.extension,
      );
      _updateTask(
        id,
        (t) => t.copyWith(
          status: DownloadStatus.completed,
          progress: 1.0,
          filePath: recordedPath,
          downloadedAt: completedAt,
          fileSize: fileSize,
        ),
      );
      _clearProgressThrottle(id);
    } on DownloadLimitReachedException catch (e) {
      if (!cancelToken.isCancelled) {
        _updateTask(
          id,
          (t) => t.copyWith(
            status: DownloadStatus.error,
            error: e.toString(),
            quotaExceeded: true,
          ),
        );
        _clearProgressThrottle(id);
      }
    } catch (e) {
      // HTML rejection — typed by both engines (DownloadContentException
      // from ResumableDownloader, DownloadHtmlException from the vendor
      // plugin): the destination is useless, never resume it. The
      // publish failure above already discarded before throwing.
      if (e is DownloadContentException || e is DownloadHtmlException) {
        if (pendingWriter != null) {
          await pendingWriter.discard();
          pendingWriter = null;
        }
      }
      if (!cancelToken.isCancelled) {
        _updateTask(
          id,
          (t) => t.copyWith(status: DownloadStatus.error, error: e.toString()),
        );
        _clearProgressThrottle(id);
      }
    } finally {
      // S6: free the slot first, so a cleanup failure below cannot leak
      // it and stall the queue; the next waiter starts immediately.
      _slotPool.release();
      // O1: this round ended — drop the foreground-service count; the
      // service stops itself when the last download finishes.
      await DownloadForegroundService.stop();
      // Keep the partial file after a failure so the next retry resumes
      // from it instead of starting over; only an explicit user cancel
      // drops it. On success the file was already renamed away.
      if (temporaryPath != null && cancelToken.isCancelled) {
        // 暂停：保留 .part / pendingWriter（下次 resume 从断点继续）；
        // 用户取消：照旧清理。标记按令牌消费，只对本轮生效（O6）。
        final wasPauseRequested = _pauseRequested.remove(cancelToken);
        if (!wasPauseRequested) {
          if (pendingWriter != null) {
            await pendingWriter.discard();
            pendingWriter = null;
          } else {
            await _deletePartial(temporaryPath);
          }
        } else if (pendingWriter != null) {
          // 暂停：把写缓冲（不足 1 MB）刷进待发布条目，否则这部分字
          // 节下次恢复时要重新下载。放在 finally 里刷才对：此时下载
          // 循环已退出，不会再有 add() 进缓冲；pauseDownload 里刷会
          // 和在途分块竞态。写失败只记日志，恢复时按条目真实大小重
          // 新对账，不会因此损坏文件。
          await _flushPendingWriterQuietly(pendingWriter);
        }
      }
      if (identical(_cancelTokens[id], cancelToken)) _cancelTokens.remove(id);
    }
  }

  /// Download [url] to [savePath] through [ResumableDownloader]: resume
  /// with `Range` + `If-Range`, reject HTML answers, flag truncated
  /// streams. Redirects are followed by Dio; no custom headers travel
  /// on this path, so a cross-host redirect carries nothing sensitive.
  Future<void> _downloadResumable(
    Dio dio,
    String url,
    String savePath, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    PendingDownloadWriter? pendingWriter,
  }) async {
    try {
      await ResumableDownloader.download(
        dio,
        url,
        savePath,
        onProgress: onProgress,
        cancelToken: cancelToken,
        pendingWriter: pendingWriter,
      );
    } on DownloadContentException {
      // Not a book: the partial (if any) is useless, never resume it.
      if (pendingWriter != null) {
        await pendingWriter.discard();
      } else {
        await _deletePartial(savePath);
      }
      rethrow;
    }
  }

  /// Best-effort flush of a pending writer on pause (O6): the writer
  /// buffers up to ~1 MB before handing a batch to the platform, and
  /// without a flush those bytes never reach the entry — the resume
  /// re-downloads them. A write failure is logged only: the resume
  /// reconciles against the entry's true size, so a failed flush
  /// cannot corrupt the file.
  Future<void> _flushPendingWriterQuietly(PendingUriWriter writer) async {
    try {
      await writer.flush();
    } catch (error) {
      logIgnored('download_pause_flush', error);
    }
  }

  Future<void> _deletePartial(String partPath) async {
    for (final path in [partPath, ResumableDownloader.metaPathFor(partPath)]) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (error) {
        logIgnored('download_partial', error);
      }
    }
  }

  Future<bool> _isOwnQuotaExhausted() async {
    try {
      final profile = await _api.getProfile();
      return profile.success &&
          profile.data != null &&
          profile.data!.downloadsLeft != null &&
          profile.data!.downloadsLeft! <= 0;
    } catch (e) {
      AppLog.report(
        'Could not check download quota: ${e.runtimeType}',
        tag: 'download_provider',
      );
      return false;
    }
  }
}
