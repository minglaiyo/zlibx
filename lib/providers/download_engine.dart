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
  Future<void> startDownload(Book book, {String? presetUrl}) {
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
      } on Object catch (error) {
        // Previous round already recorded its own error status — this
        // only swallows the rethrow (审查 v2 P2-2：留一行轨迹).
        logIgnored('download_previous_round', error);
      }
    }
    // Re-check: another round may have started while we waited.
    if (_isDownloadActive(id)) return;

    // E1 仅 Wi-Fi 下载：开关打开且当前没有 Wi-Fi/以太网时拒绝启动，
    // 任务记为带 wifiOnlyBlocked 旗标的错误态——下载页据此解释，到
    // Wi-Fi 后照常重试。放在加任务之前：不开任务就不占队列。
    if (await _wifiOnlyBlocked()) {
      _updateOrAddTask(
        DownloadTask(
          id: id,
          book: book,
          status: DownloadStatus.error,
          error: 'wifi-only',
          wifiOnlyBlocked: true,
          needsFreshLink: presetUrl != null,
          presetUrl: presetUrl,
        ),
      );
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
        presetUrl: presetUrl,
      ),
    );

    // S6: wait for a free slot (FIFO, keyed by task id so 置顶 can
    // reorder). Callers fire this with `unawaited`, so the wait never
    // blocks the UI; the task shows as pending while queued.
    await _slotPool.acquire(key: id);
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
      // permission is needed on any Android version. The save path
      // carries the organize-mode subfolder, so the .part file and the
      // staged file live in the same subfolder as the published book.
      final finalPath =
          await _buildSavePath(book) ??
          '${await _resolveSaveDir()}/${_buildSafeFileName(book)}';

      if (cancelToken.isCancelled) return;

      temporaryPath = '$finalPath.part';

      // 来源 sidecar（2026-11-21 恢复链路）：把书的完整身份（含外部
      // 直链）落在盘上，进程死亡后的启动恢复才能还原出"能续传的任务"
      // ——光靠文件名反解分不清 z 书和外部书（两者的 id 都是数字），
      // 也拿不到作者/封面/hash/直链。每轮重写；成功与用户取消时删除，
      // 暂停/杀进程时保留，恢复逻辑据此重建。
      await _writeSidecarQuietly(temporaryPath, book, presetUrl);

      // Update to downloading. Keep the existing progress: a fresh
      // download starts at 0 (the task was created with progress 0), and
      // a resume continues from where it paused — resetting to 0 would
      // flash the bar back to zero on every resume (O13).
      _updateTask(id, (t) => t.copyWith(status: DownloadStatus.downloading));

      // Write to a task-specific temporary file so cancellation never leaves
      // a partial book under its final name.
      final alreadyExists = await File(finalPath).exists();
      // Pending MediaStore entry (Android 10+): only when actually
      // downloading. An already-present file needs no writer — creating
      // one would publish an empty entry and record its URI instead of
      // the real file. Any failure here keeps the staging flow
      // (pendingWriter stays null).
      if (Platform.isAndroid && !alreadyExists) {
        pendingWriter = await PendingUriWriter.resume(savePath: temporaryPath);
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
          subfolder: _downloadSubfolder(book),
        );
      }
      // O1: start (or keep) the foreground service so the download
      // survives backgrounding; the notification shows progress.
      await DownloadForegroundService.start();

      // 恢复出来的任务可能没有 hash（文件名反解无 hash 可言）：eapi
      // 对空 hash 的 file 端点直接 400（不给"Invalid hash"，vendor 的
      // 标题解析兜底接不住）。按标题搜索一次，一石二鸟：解析出真
      // hash 续传 + 把搜索命中里的完整书（作者/封面）回填进任务行——
      // 残片恢复的书没有这些字段，下载页此前只能显示"未知作者"和占
      // 位封面。搜索失败/无命中照旧往下走，错误态由下面的 catch 带
      // needsFreshLink 引导回详情页。
      var effectiveBook = book;
      if (presetUrl == null &&
          !alreadyExists &&
          (book.hash == null || book.hash!.isEmpty) &&
          book.title.isNotEmpty) {
        final match = await _searchMatchBook(book);
        if (match != null &&
            match.hash != null &&
            match.hash!.isNotEmpty) {
          effectiveBook = match;
          _updateTask(id, (t) => t.copyWith(book: effectiveBook));
        }
      }

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
            effectiveBook.id.toString(),
            effectiveBook.hash ?? '',
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
            subfolder: _downloadSubfolder(book),
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

      // 外部源内容完整性校验（审查 2026-11-21 5.1）：Anna/LibGen 以
      // 文件 MD5 标识文件（synthesizeExternalBook 把它放进 book.hash），
      // 下载完成后流式比对——现有检查只覆盖"HTML 冒充文件"与"流截
      // 断"，长度一致的内容损坏/镜像返回错文件漏网。z 站 hash 不是文
      // 件 MD5，跳过。校验失败：删掉发布出去的文件与 sidecar，任务错
      // 误态引导换镜像重试；哈希算不出（通道失败）放行——不能因校验
      // 通道故障把下好的书扔掉。
      if (presetUrl != null && (book.hash?.isNotEmpty ?? false)) {
        final actual = await DownloadForegroundService.md5OfContent(
          recordedPath,
        );
        if (actual == null) {
          logIgnored('download_md5', StateError('hash unavailable'));
        } else if (actual.toLowerCase() != book.hash!.toLowerCase()) {
          await MediaStoreFiles.delete(recordedPath);
          await _deleteSidecarQuietly(temporaryPath);
          _updateTask(
            id,
            (t) => t.copyWith(
              status: DownloadStatus.error,
              error: '文件校验失败：镜像返回的内容与来源不符，请换镜像重试',
              needsFreshLink: true,
            ),
          );
          _clearProgressThrottle(id);
          return;
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
      // 书已落地：来源 sidecar 使命结束。
      await _deleteSidecarQuietly(temporaryPath);
      // E3+F4: 完成通知（独立于进度通知的普通重要性渠道），点击直达
      // 文件，副文本带当日剩余额度（best-effort，取不到就省略）。
      unawaited(_notifyCompletedWithQuota(book, recordedPath));
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
        if (temporaryPath != null) {
          await _deleteSidecarQuietly(temporaryPath);
        }
      }
      if (!cancelToken.isCancelled) {
        _updateTask(
          id,
          (t) => t.copyWith(
            status: DownloadStatus.error,
            error: e.toString(),
            // hash 缺失的书（启动恢复的反解任务）连不上 eapi 时，
            // 引导回详情页重新下载——恢复场景的失败不该只有一句
            // "下载失败"。
            needsFreshLink:
                presetUrl == null && (book.hash?.isEmpty ?? true),
          ),
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

  /// E3+F4: 完成通知——先查一次当日剩余额度拼进副文本。额度查询
  /// 失败不影响通知本身（降级为不带额度）。getProfile 的响应里
  /// downloadsLeft 是"今日剩余次数"（与额度耗尽弹窗同一来源）。
  Future<void> _notifyCompletedWithQuota(Book book, String recordedPath) async {
    String detail = '下载完成';
    try {
      final profile = await _api.getProfile();
      final left = profile.data?.downloadsLeft;
      if (left != null) detail = '下载完成 · 今日剩余 $left 本';
    } on Object catch (error) {
      logIgnored('download_completed_quota', error);
    }
    await DownloadForegroundService.notifyCompleted(
      title: book.title,
      uri: recordedPath,
      mimeType: MediaStoreFiles.mimeTypeForExtension(book.extension),
      detail: detail,
    );
  }

  /// E1 仅 Wi-Fi 下载：开关打开且当前没有 Wi-Fi/以太网时返回 true
  /// （移动数据 / 无网 / 其他计费连接都算）。探测失败放行——不能因
  /// 为开关检查失败把下载挡死。
  Future<bool> _wifiOnlyBlocked() async {
    try {
      if (HiveService.settingsBox.get('wifiOnlyDownloads') != true) {
        return false;
      }
      final results = await Connectivity().checkConnectivity();
      return !results.contains(ConnectivityResult.wifi) &&
          !results.contains(ConnectivityResult.ethernet);
    } on Object catch (error) {
      logIgnored('download_wifi_only', error);
      return false;
    }
  }

  /// E2 下载队列置顶：把 pending 任务挪到队列最前——slot 池里插队
  /// （下一个空出的槽位给它）+ 状态列表里打 pinned 旗（展示排序里
  /// pinned 的 pending 排在其他 pending 之前）。已在下载 / 不在队列
  /// 的任务是无害 no-op。
  void pinToTop(String id) {
    final matches = state.where((t) => t.id == id && t.status == DownloadStatus.pending).toList();
    if (matches.isEmpty) return;
    _slotPool.prioritize(id);
    _updateTask(id, (t) => t.copyWith(pinned: true));
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
    for (final path in [
      partPath,
      ResumableDownloader.metaPathFor(partPath),
      '$partPath.download.json',
    ]) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (error) {
        logIgnored('download_partial', error);
      }
    }
  }

  /// 来源 sidecar（`<part>.download.json`）：每轮下载开始时重写。写
  /// 失败只记日志——sidecar 缺席时启动恢复退回文件名反解（z 书仍可
  /// 恢复，外部书不行）。
  Future<void> _writeSidecarQuietly(
    String temporaryPath,
    Book book,
    String? presetUrl,
  ) async {
    try {
      await File('$temporaryPath.download.json').writeAsString(
        jsonEncode({
          'id': book.id,
          'title': book.title,
          'author': book.author,
          'cover': book.cover,
          'extension': book.extension,
          'hash': book.hash,
          if (presetUrl != null) 'presetUrl': presetUrl,
        }),
      );
    } on Object catch (error) {
      logIgnored('download_sidecar_write', error);
    }
  }

  /// 删来源 sidecar。静默：文件不在/删除失败都无所谓。
  Future<void> _deleteSidecarQuietly(String temporaryPath) async {
    try {
      final f = File('$temporaryPath.download.json');
      if (await f.exists()) await f.delete();
    } on Object catch (error) {
      logIgnored('download_sidecar_delete', error);
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
