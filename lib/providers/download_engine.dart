part of 'download_provider.dart';

/// Whether [hash] is a 32-char hex MD5 digest worth verifying a
/// downloaded file against (H2). External-source parsers fall back to
/// the book title or a numeric id when a search row carries no md5 link;
/// those are not digests and must never trigger the delete-on-mismatch
/// path — a non-hex "hash" can never match the file's real MD5, so
/// verifying it would delete a good download.
bool isVerifiableMd5(String? hash) =>
    hash != null && RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hash);

/// Plan item 10: the retry schedule — exponential backoff, at most 3
/// retries (2s, 4s, 8s). A top-level const, not a local, so tests can pin
/// it: the schedule is part of the error table's contract.
const downloadRetryDelays = [
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
];

/// M4: whether a download failure is worth retrying with backoff.
/// Only transient transport failures: a dropped connection, a 5xx
/// answer, or a stream that ended early. A content error (the server
/// answered HTML instead of a book), a magic mismatch (the bytes are
/// not the book), quota exhaustion, or a user cancel never retries.
/// The vendor plugin reports a truncation as a StateError with a fixed
/// message prefix (see _downloadOnce), so that is recognised too.
///
/// Plan item 10: the 5xx branch asks the error table — a 5xx carrying
/// a refusal text ("Access denied") is not transient.
bool isRetryableDownloadError(Object e) {
  if (e is DownloadTruncatedException) return true;
  if (e is StateError &&
      e.message.toString().startsWith('download truncated:')) {
    return true;
  }
  if (e is DioException) {
    if (e.type == DioExceptionType.connectionError) return true;
    final status = e.response?.statusCode;
    if (status != null && status >= 500 && status < 600) {
      return classifyZlibError(status: status, message: zlibErrorText(e)) ==
          ZlibErrorKind.serverRetryable;
    }
  }
  return false;
}

/// Mutable per-round state shared by the `_runDownloadRound` stages
/// (P1-1). The old single body passed everything through locals; the
/// split stages pass one of these instead, so a stage can set what the
/// next stage — and the error/finally handling in `_runDownloadRound`
/// — reads, without changing the order anything happens in.
///
/// `subfolder` and `cancelToken` are set by `_preflight` before the
/// round's try/finally starts, so they are always initialised by the
/// time the orchestrator's catch/finally can read them. `finalPath`
/// and `temporaryPath` are set by `_resolveSource` (unless the round
/// was cancelled before the paths were built, in which case the
/// orchestrator returns before the later stages run).
class _DownloadRoundState {
  _DownloadRoundState({
    required this.book,
    required this.presetUrl,
    required this.source,
    required this.customSubfolder,
  }) : id = book.id.toString(),
       effectiveBook = book;

  final Book book;
  final String? presetUrl;
  final BookSource? source;
  final String? customSubfolder;
  final String id;

  /// Set by `_preflight`: the subfolder the .part file, the pending
  /// entry and the published book all share (#95).
  late final String? subfolder;

  /// Set by `_preflight`: this round's cancel token, also registered
  /// in the notifier's cancel-token map so pause/cancel can reach it.
  late final CancelToken cancelToken;

  /// Set by `_resolveSource`: the staged file's final location and
  /// its `.part` path.
  String? finalPath;
  String? temporaryPath;

  /// Set by `_resolveSource` on Android 10+: the pending MediaStore
  /// entry the bytes stream into. Null = staging fallback (.part file
  /// + publish copy). Nulled by `_finalize` once the entry is
  /// published.
  PendingUriWriter? pendingWriter;

  /// Set by `_resolveSource`: the book file is already on disk, so the
  /// transfer stage is skipped and `_finalize` only publishes it.
  bool alreadyExists = false;

  /// Starts as [book]; `_resolveSource` may replace it with the fuller
  /// book found by the title search (real hash, author, cover) when
  /// the task was restored without a hash.
  Book effectiveBook;
}

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
    unawaited(
      startDownload(
        task.book,
        presetUrl: task.presetUrl,
        source: task.source,
        customSubfolder: task.customSubfolder,
      ),
    );
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
  /// [source] 是这次下载的来源（#143）：外部直下与换源下载由调用方
  /// 传入，z 站下载不传——presetUrl 为空时默认就是 z 站。任务、
  /// 历史记录与来源 sidecar 都记这个值，下载页据此标注来源。
  ///
  /// [customSubfolder] 是这次下载指定的子文件夹（#95）：用户在详情
  /// 页长按下载按钮选的，`Download/zlibx` 下的文件夹名；null = 用
  /// 分类模式默认。任务、历史记录与来源 sidecar 都记这个值，恢复/
  /// 重试沿用它。
  ///
  /// Thin wrapper around [_runDownloadRound]: it records the round so
  /// a later call for the same book waits for this one to settle
  /// instead of racing it on the same .part / pending entry.
  Future<void> startDownload(
    Book book, {
    String? presetUrl,
    BookSource? source,
    String? customSubfolder,
  }) {
    final id = book.id.toString();
    final previous = _runningRounds[id];
    final round = _runDownloadRound(
      book,
      presetUrl: presetUrl,
      source: source ?? _defaultSource(presetUrl),
      customSubfolder: customSubfolder,
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

  /// 默认来源（#143）：调用方没传 source 时，presetUrl 为空就是 z
  /// 站直下；有 presetUrl 但没传 source 说明调用方漏了，记 null
  /// （下载页不标），不猜。
  static BookSource? _defaultSource(String? presetUrl) =>
      presetUrl == null ? BookSource.zlibrary : null;

  /// One download round, split into stages (P1-1) — a pure extraction
  /// of the former single body, no behaviour change:
  ///
  /// * [_preflight] — duplicate-round guard, wait for the previous
  ///   round, Wi-Fi-only gate, pending task, slot acquire.
  /// * [_resolveSource] — save path, sidecar, pending MediaStore
  ///   entry, foreground service, hash recovery by title search.
  /// * [_transfer] — the download attempts with exponential-backoff
  ///   retry over the resumable transport.
  /// * [_finalize] — publish into Downloads, MD5 check, history,
  ///   completion notification, completed task.
  ///
  /// The error mapping and the slot / cancel cleanup stay here, so the
  /// stages never have to reason about each other's failure paths.
  /// The round only enters the try once [_preflight] has acquired a
  /// slot; the queued-cancel path releases its slot inside
  /// [_preflight] itself.
  Future<void> _runDownloadRound(
    Book book, {
    String? presetUrl,
    BookSource? source,
    String? customSubfolder,
    Future<void>? previous,
  }) async {
    final ctx = _DownloadRoundState(
      book: book,
      presetUrl: presetUrl,
      source: source,
      customSubfolder: customSubfolder,
    );
    // _preflight returns false when the round must not start (a round
    // is already active, Wi-Fi-only blocked it, or it was cancelled
    // while queued).
    if (!await _preflight(ctx, previous: previous)) return;
    try {
      await _resolveSource(ctx);
      if (ctx.cancelToken.isCancelled) return;
      await _transfer(ctx);
      if (ctx.cancelToken.isCancelled) return;
      if (identical(_cancelTokens[ctx.id], ctx.cancelToken)) {
        _cancelTokens.remove(ctx.id);
      }
      await _finalize(ctx);
    } on DownloadMagicException catch (e) {
      // Plan item 8: the bytes are not the book — the destination is
      // garbage, never resume it. Delete the partial and its sidecars
      // (the engines already deleted the file itself; this also drops
      // the .meta and the source sidecar), and flag the task so the
      // downloads screen can say so. The retry is manual, from zero.
      if (!ctx.cancelToken.isCancelled) {
        if (ctx.pendingWriter != null) {
          await ctx.pendingWriter!.discard();
          ctx.pendingWriter = null;
        }
        if (ctx.temporaryPath != null) {
          await _deletePartial(ctx.temporaryPath!);
        }
        _updateTask(
          ctx.id,
          (t) => t.copyWith(
            status: DownloadStatus.error,
            error: e.toString(),
            magicMismatch: true,
          ),
        );
        _clearProgressThrottle(ctx.id);
      }
    } on DownloadLimitReachedException catch (e) {
      if (!ctx.cancelToken.isCancelled) {
        _updateTask(
          ctx.id,
          (t) => t.copyWith(
            status: DownloadStatus.error,
            error: e.toString(),
            quotaExceeded: true,
          ),
        );
        _clearProgressThrottle(ctx.id);
      }
    } catch (e) {
      // HTML rejection — typed by both engines (DownloadContentException
      // from ResumableDownloader, DownloadHtmlException from the vendor
      // plugin): the destination is useless, never resume it. The
      // publish failure above already discarded before throwing.
      if (e is DownloadContentException || e is DownloadHtmlException) {
        if (ctx.pendingWriter != null) {
          await ctx.pendingWriter!.discard();
          ctx.pendingWriter = null;
        }
        if (ctx.temporaryPath != null) {
          await _deleteSidecarQuietly(ctx.temporaryPath!);
        }
      }
      if (!ctx.cancelToken.isCancelled) {
        _updateTask(
          ctx.id,
          (t) => t.copyWith(
            status: DownloadStatus.error,
            error: e.toString(),
            // Plan item 10: a download failure that says the quota is
            // gone ("daily limit") is a quota failure even when the
            // server never raised DownloadLimitReachedException.
            quotaExceeded:
                classifyZlibError(message: zlibErrorText(e)) ==
                ZlibErrorKind.quotaExhausted,
            // hash 缺失的书（启动恢复的反解任务）连不上 eapi 时，
            // 引导回详情页重新下载——恢复场景的失败不该只有一句
            // "下载失败"。
            needsFreshLink:
                ctx.presetUrl == null && (ctx.book.hash?.isEmpty ?? true),
          ),
        );
        _clearProgressThrottle(ctx.id);
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
      if (ctx.temporaryPath != null && ctx.cancelToken.isCancelled) {
        // 暂停：保留 .part / pendingWriter（下次 resume 从断点继续）；
        // 用户取消：照旧清理。标记按令牌消费，只对本轮生效（O6）。
        final wasPauseRequested = _pauseRequested.remove(ctx.cancelToken);
        if (!wasPauseRequested) {
          if (ctx.pendingWriter != null) {
            await ctx.pendingWriter!.discard();
            ctx.pendingWriter = null;
          } else {
            await _deletePartial(ctx.temporaryPath!);
          }
        } else if (ctx.pendingWriter != null) {
          // 暂停：把写缓冲（不足 1 MB）刷进待发布条目，否则这部分字
          // 节下次恢复时要重新下载。放在 finally 里刷才对：此时下载
          // 循环已退出，不会再有 add() 进缓冲；pauseDownload 里刷会
          // 和在途分块竞态。写失败只记日志，恢复时按条目真实大小重
          // 新对账，不会因此损坏文件。
          await _flushPendingWriterQuietly(ctx.pendingWriter!);
        }
      }
      if (identical(_cancelTokens[ctx.id], ctx.cancelToken)) {
        _cancelTokens.remove(ctx.id);
      }
    }
  }

  /// Stage 1 — gates and enqueue: duplicate-round guard, wait for the
  /// previous round to settle, Wi-Fi-only gate, pending task, slot
  /// acquire. Returns false when the round must not start. No quota
  /// check lives here: there is no upfront quota probe — quota
  /// exhaustion is only detected during [_transfer] (the server
  /// raising [DownloadLimitReachedException], or the post-failure
  /// profile check in the z-library path).
  Future<bool> _preflight(
    _DownloadRoundState ctx, {
    Future<void>? previous,
  }) async {
    // Fast path: a round is already running for this book.
    if (_isDownloadActive(ctx.id)) return false;
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
    if (_isDownloadActive(ctx.id)) return false;

    // #95：这轮实际用的子文件夹，算一次、三处共用（暂存路径、待发
    // 布条目、正式发布），保证同一本书三处落在同一个文件夹。
    ctx.subfolder = effectiveSubfolder(ctx.book, ctx.customSubfolder);

    // E1 仅 Wi-Fi 下载：开关打开且当前没有 Wi-Fi/以太网时拒绝启动，
    // 任务记为带 wifiOnlyBlocked 旗标的错误态——下载页据此解释，到
    // Wi-Fi 后照常重试。放在加任务之前：不开任务就不占队列。
    if (await _wifiOnlyBlocked()) {
      _updateOrAddTask(
        DownloadTask(
          id: ctx.id,
          book: ctx.book,
          status: DownloadStatus.error,
          error: 'wifi-only',
          wifiOnlyBlocked: true,
          needsFreshLink: ctx.presetUrl != null,
          presetUrl: ctx.presetUrl,
          source: ctx.source,
          customSubfolder: ctx.customSubfolder,
        ),
      );
      return false;
    }

    // Add or update task to pending
    final cancelToken = CancelToken();
    ctx.cancelToken = cancelToken;
    _cancelTokens[ctx.id] = cancelToken;
    _updateOrAddTask(
      DownloadTask(
        id: ctx.id,
        book: ctx.book,
        status: DownloadStatus.pending,
        needsFreshLink: ctx.presetUrl != null,
        presetUrl: ctx.presetUrl,
        source: ctx.source,
        customSubfolder: ctx.customSubfolder,
      ),
    );

    // S6: wait for a free slot (FIFO, keyed by task id so 置顶 can
    // reorder). Callers fire this with `unawaited`, so the wait never
    // blocks the UI; the task shows as pending while queued.
    await _slotPool.acquire(key: ctx.id);
    // Cancelled while queued: give the slot back and stop without
    // downloading. (The round's `finally` never runs on this path, so
    // the release has to happen here.)
    if (cancelToken.isCancelled) {
      _slotPool.release();
      // 排队期间被暂停：任务已由 pauseDownload 置为 paused，.part 还
      // 没有开始写，无需清理；只要消费掉本轮的暂停标记。
      _pauseRequested.remove(cancelToken);
      return false;
    }
    return true;
  }

  /// Stage 2 — resolve the source: build the save path, write the
  /// source sidecar, create or resume the pending MediaStore entry,
  /// start the foreground service, and recover a missing hash by
  /// title search. Returns early (leaving `ctx.temporaryPath` null)
  /// when the round was cancelled right after the path was built;
  /// the orchestrator then returns before [_transfer] runs.
  Future<void> _resolveSource(_DownloadRoundState ctx) async {
    // Downloads go to the app-specific external dir: no storage
    // permission is needed on any Android version. The save path
    // carries the organize-mode subfolder, so the .part file and the
    // staged file live in the same subfolder as the published book.
    // #95：用户给这本书指定了文件夹就用它，否则走分类模式默认。
    final finalPath =
        await _buildSavePath(ctx.book, subfolderOverride: ctx.customSubfolder) ??
        '${await _resolveSaveDir()}/${_buildSafeFileName(ctx.book)}';

    if (ctx.cancelToken.isCancelled) return;

    ctx.finalPath = finalPath;
    ctx.temporaryPath = '$finalPath.part';

    // 来源 sidecar（2026-11-21 恢复链路）：把书的完整身份（含外部
    // 直链）落在盘上，进程死亡后的启动恢复才能还原出"能续传的任务"
    // ——光靠文件名反解分不清 z 书和外部书（两者的 id 都是数字），
    // 也拿不到作者/封面/hash/直链。每轮重写；成功与用户取消时删除，
    // 暂停/杀进程时保留，恢复逻辑据此重建。
    await _writeSidecarQuietly(
      ctx.temporaryPath!,
      ctx.book,
      ctx.presetUrl,
      ctx.source,
      ctx.customSubfolder,
    );

    // Update to downloading. Keep the existing progress: a fresh
    // download starts at 0 (the task was created with progress 0), and
    // a resume continues from where it paused — resetting to 0 would
    // flash the bar back to zero on every resume (O13).
    _updateTask(ctx.id, (t) => t.copyWith(status: DownloadStatus.downloading));

    // Write to a task-specific temporary file so cancellation never leaves
    // a partial book under its final name.
    final alreadyExists = await File(finalPath).exists();
    ctx.alreadyExists = alreadyExists;
    // Pending MediaStore entry (Android 10+): only when actually
    // downloading. An already-present file needs no writer — creating
    // one would publish an empty entry and record its URI instead of
    // the real file. Any failure here keeps the staging flow
    // (pendingWriter stays null).
    if (Platform.isAndroid && !alreadyExists) {
      var writer = await PendingUriWriter.resume(savePath: ctx.temporaryPath!);
      if (writer != null && !await MediaStoreFiles.exists(writer.uri)) {
        // The pending entry vanished (user deleted it in Files);
        // the sidecar is stale — drop it and start a fresh entry.
        await writer.discard();
        writer = null;
      }
      writer ??= await PendingUriWriter.create(
        displayName: _buildSafeFileName(ctx.book),
        mimeType: MediaStoreFiles.mimeTypeForExtension(ctx.book.extension),
        savePath: ctx.temporaryPath!,
        // #95：和暂存路径、正式发布用同一个生效文件夹。
        subfolder: ctx.subfolder,
      );
      ctx.pendingWriter = writer;
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
    if (ctx.presetUrl == null &&
        !alreadyExists &&
        (ctx.book.hash == null || ctx.book.hash!.isEmpty) &&
        ctx.book.title.isNotEmpty) {
      final match = await _searchMatchBook(ctx.book);
      if (match != null && match.hash != null && match.hash!.isNotEmpty) {
        ctx.effectiveBook = match;
        _updateTask(ctx.id, (t) => t.copyWith(book: ctx.effectiveBook));
      }
    }
  }

  /// Stage 3 — transfer: move the bytes with exponential-backoff
  /// retry over the resumable transport. A present file skips the
  /// transfer ([_resolveSource] already recorded it). Failures
  /// propagate to the orchestrator's error mapping; only transient
  /// transport failures retry.
  Future<void> _transfer(_DownloadRoundState ctx) async {
    if (ctx.alreadyExists) return;
    // temporaryPath is non-null here: _resolveSource assigned it, and
    // a round cancelled before that point never reaches this stage.
    // Hoist it into a final local: a closure does not inherit the
    // outer flow's null promotion, so passing the field directly
    // fails analyze.
    final savePath = ctx.temporaryPath!;
    final cancelToken = ctx.cancelToken;

    void onProgress(int received, int total) {
      // `total` can be 0 (empty body / CDN without length): only a
      // positive total yields a valid fraction — 0/0 would push a
      // NaN into the state and straight into the progress bar.
      if (total > 0) {
        final progress = received / total;
        _updateProgress(ctx.id, progress);
        _notifyDownloadProgress(progress);
      }
    }

    // M4: retry transient failures with exponential backoff. The
    // partial (.part / pending entry) survives each attempt, so a
    // retry resumes instead of restarting. Only connection errors,
    // 5xx and truncations retry — a content error (HTML instead of
    // a book), a magic mismatch (the bytes are not the book),
    // quota exhaustion, or a user cancel never does.
    Future<void> downloadAttempt() async {
      if (ctx.presetUrl != null) {
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
            ctx.presetUrl!,
            savePath,
            onProgress: onProgress,
            cancelToken: cancelToken,
            pendingWriter: ctx.pendingWriter,
          );
        } finally {
          dio.close();
        }
      } else {
        // 默认路径：用户自己 z站 账号查 URL + 下载
        try {
          await _api.downloadBook(
            ctx.effectiveBook.id.toString(),
            ctx.effectiveBook.hash ?? '',
            savePath,
            onProgress: onProgress,
            cancelToken: cancelToken,
            title: ctx.book.title,
            pendingWriter: ctx.pendingWriter,
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
    }

    for (var attempt = 0; ; attempt++) {
      try {
        await downloadAttempt();
        break;
      } on Object catch (e) {
        if (cancelToken.isCancelled ||
            !isRetryableDownloadError(e) ||
            attempt >= downloadRetryDelays.length) {
          rethrow;
        }
        logIgnored('download_retry', e);
        await Future.delayed(downloadRetryDelays[attempt]);
        if (cancelToken.isCancelled) return;
      }
    }
  }

  /// Stage 4 — finalize: publish the finished bytes into Downloads,
  /// verify the MD5 for external-source downloads, record history,
  /// notify, and mark the task completed. A publish failure throws
  /// (the orchestrator maps it to an error task); an MD5 mismatch
  /// records the error task itself and returns, so the orchestrator
  /// simply ends the round.
  Future<void> _finalize(_DownloadRoundState ctx) async {
    final completedAt = DateTime.now();
    int fileSize;

    // The final location, and where the history records it.
    var recordedPath = ctx.finalPath!;
    final writer = ctx.pendingWriter;
    if (writer != null) {
      // Flush the writer's buffer and publish the pending entry
      // (clear IS_PENDING): the book is already in Downloads/zlibx.
      await writer.flush();
      if (!await writer.finish()) {
        // Publishing failed (e.g. the entry was removed): the book
        // never reached Downloads — fail, don't record a dead URI.
        await writer.discard();
        ctx.pendingWriter = null;
        throw StateError(
          'could not publish the download into Downloads/zlibx',
        );
      }
      recordedPath = writer.uri;
      // After flush() the buffer is empty, so bytesWritten is the
      // total committed size — the file size for the task record.
      fileSize = writer.bytesWritten;
      ctx.pendingWriter = null;
    } else {
      if (await File(ctx.temporaryPath!).exists()) {
        await File(ctx.temporaryPath!).rename(ctx.finalPath!);
      }
      fileSize = await File(ctx.finalPath!).length();

      // Publish into the public Downloads/zlibx folder (MediaStore,
      // Android 10+). On failure keep the app-specific file and
      // report success with that location — the download itself
      // still counts.
      if (Platform.isAndroid) {
        final uri = await MediaStoreFiles.publishToDownloads(
          sourcePath: ctx.finalPath!,
          displayName: _buildSafeFileName(ctx.book),
          mimeType: MediaStoreFiles.mimeTypeForExtension(ctx.book.extension),
          // #95：和暂存路径、待发布条目用同一个生效文件夹。
          subfolder: ctx.subfolder,
        );
        if (uri != null) {
          recordedPath = uri;
          try {
            await File(ctx.finalPath!).delete();
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
    // H2：只有 book.hash 是 32 位 hex 才校验。外部源解析器拿不到
    // md5 时会把书名/数字 id 塞进来（libgen_service、external_search
    // 的兜底，那是给 externalBookId 用的，不能改成 ''），那种 hash
    // 永远比对不上，会删掉已下好的文件。非 hex 直接跳过校验。
    final expectedMd5 = ctx.book.hash;
    if (ctx.presetUrl != null &&
        expectedMd5 != null &&
        isVerifiableMd5(expectedMd5)) {
      final actual = await DownloadForegroundService.md5OfContent(
        recordedPath,
      );
      if (actual == null) {
        logIgnored('download_md5', StateError('hash unavailable'));
      } else if (actual.toLowerCase() != expectedMd5.toLowerCase()) {
        await MediaStoreFiles.delete(recordedPath);
        await _deleteSidecarQuietly(ctx.temporaryPath!);
        _updateTask(
          ctx.id,
          (t) => t.copyWith(
            status: DownloadStatus.error,
            error: '文件校验失败：镜像返回的内容与来源不符，请换镜像重试',
            needsFreshLink: true,
          ),
        );
        _clearProgressThrottle(ctx.id);
        return;
      }
    }

    // Orphaned-row recovery (2026-11-26): clearing the app's data
    // can disown the MediaStore row (owner_package_name NULL), after
    // which the stored content:// URI no longer opens although the
    // file is still on disk. Record the real path now, while the row
    // is still owned and the query works, so the history check can
    // fall back to the file itself. A plain staging path resolves
    // to itself; a failed resolution stores nothing (no behavior
    // change).
    final realPath = await MediaStoreFiles.realPath(recordedPath);

    // Save to download history (with cover and extension for persistence)
    await _storage.addToDownloadHistory(
      ctx.book.id.toString(),
      ctx.book.title,
      ctx.book.author,
      recordedPath,
      cover: ctx.book.cover,
      extension: ctx.book.extension,
      source: ctx.source?.name,
      // #95：记用户指定的那个（原始值）；读回后重新算生效文件夹。
      customSubfolder: ctx.customSubfolder,
      realPath: realPath,
    );
    // 书已落地：来源 sidecar 使命结束。
    await _deleteSidecarQuietly(ctx.temporaryPath!);
    // E3+F4: 完成通知（独立于进度通知的普通重要性渠道），点击直达
    // 文件，副文本带当日剩余额度（best-effort，取不到就省略）。
    unawaited(_notifyCompletedWithQuota(ctx.book, recordedPath));
    _updateTask(
      ctx.id,
      (t) => t.copyWith(
        status: DownloadStatus.completed,
        progress: 1.0,
        filePath: recordedPath,
        downloadedAt: completedAt,
        fileSize: fileSize,
      ),
    );
    _clearProgressThrottle(ctx.id);
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
    } on DownloadMagicException {
      // Plan item 8: not the book — same treatment as an HTML answer.
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

  /// Staging traces of a removed task: the .part file, its .meta
  /// validator, the pending sidecar and the source sidecar. In-progress
  /// tasks have no published file and no history row, so these are the
  /// only traces — leave them and the next launch's
  /// _recoverPartialDownloads hangs the task back as paused.
  /// The organize mode may have changed since the download started, so
  /// both the recomputed path and the flat top-level path are cleaned.
  @override
  Future<void> _deleteStagingTracesForTask(DownloadTask task) async {
    final partPaths = <String>{};
    // _buildSavePath never throws (it returns null on error); the
    // recomputed path is the one the engine used for this book.
    final finalPath = await _buildSavePath(
      task.book,
      subfolderOverride: task.customSubfolder,
    );
    if (finalPath != null) partPaths.add('$finalPath.part');
    // The organize mode may have changed since the download started;
    // the flat top-level path is the other place a .part can sit.
    // _resolveSaveDir can throw when storage is unavailable (e.g. a
    // test without Hive) — the cleanup is best-effort, never fatal.
    try {
      partPaths.add(
        '${await _resolveSaveDir()}/${_buildSafeFileName(task.book)}.part',
      );
    } on Object catch (error) {
      logIgnored('download_partial', error);
    }
    for (final partPath in partPaths) {
      await _deletePartial(partPath);
      // _deletePartial drops .part / .meta / .download.json; the
      // pending sidecar (<part>.pending.json) is only discarded
      // through the writer, which is gone for a paused task.
      try {
        final pending = File('$partPath.pending.json');
        if (await pending.exists()) await pending.delete();
      } on Object catch (error) {
        logIgnored('download_partial', error);
      }
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
    BookSource? source,
    String? customSubfolder,
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
          if (source != null) 'source': source.name,
          if (customSubfolder != null) 'customSubfolder': customSubfolder,
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
