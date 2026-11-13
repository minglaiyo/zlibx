part of 'download_provider.dart';

/// The download execution cluster: startDownload plus the resumable
/// transport and its failure cleanup.
mixin _DownloadEngineMixin on _DownloadPathsMixin {
  /// S6: at most this many downloads run at once (the review suggests
  /// 2–3). A field, not a local: the pool must survive `ref.invalidate`
  /// re-running build() on the same notifier instance, and a queued
  /// download's wait must outlive the call that started it.
  final DownloadSlotPool _slotPool = DownloadSlotPool();

  /// Start a download.
  ///
  /// 默认走 ZLibraryApi（用户自己账号查 URL + 下载）。
  /// [presetUrl] 传入时跳过 URL 获取，直接用此 URL 下文件 —
  /// 用于外部源（Anna's Archive / LibGen）解析出的直链。
  /// 不支持自定义请求头（S5）：dio 自动跟随重定向时会把自定义头
  /// 带到任意目标主机，这个口子不开。以前留过 LAN 传书的
  /// `presetHeaders`（`X-Olib-Token`），功能无调用方，已删除。
  Future<void> startDownload(
    Book book, {
    String? presetUrl,
  }) async {
    final id = book.id.toString();

    // Check if already downloading
    if (state.any(
      (t) =>
          t.id == id &&
          (t.status == DownloadStatus.downloading ||
              t.status == DownloadStatus.pending),
    )) {
      return;
    }

    // Add or update task to pending
    final cancelToken = CancelToken();
    _cancelTokens[id] = cancelToken;
    _updateOrAddTask(
      DownloadTask(
        id: id,
        book: book,
        status: DownloadStatus.pending,
        needsFreshLink: presetUrl != null,
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

      // Update to downloading
      _updateTask(
        id,
        (t) => t.copyWith(status: DownloadStatus.downloading, progress: 0.0),
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
      if (!alreadyExists && presetUrl != null) {
        // presetUrl 路径（外部源解析链接）：直接 stream 到本地，
        // 用独立 Dio，不带 z站 cookie / auth，也不带任何自定义头 —
        // followRedirects 必须为 true：LibGen get.php 307 跳到 CDN
        // 文件，不跟随会把重定向响应本身存成文件；跟随时不带上层
        // 自定义头，所以跨主机跳转没有凭据外泄面（S5）。
        // receiveTimeout: null = 不限接收超时：大文件慢速网络不能被打断。
        final dio = createDio(receiveTimeout: null);
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
            }
          },
          cancelToken: cancelToken,
          pendingWriter: pendingWriter,
        );
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
      // Keep the partial file after a failure so the next retry resumes
      // from it instead of starting over; only an explicit user cancel
      // drops it. On success the file was already renamed away.
      if (temporaryPath != null && cancelToken.isCancelled) {
        if (pendingWriter != null) {
          await pendingWriter.discard();
          pendingWriter = null;
        } else {
          await _deletePartial(temporaryPath);
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
