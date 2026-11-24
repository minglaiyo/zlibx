// Downloads domain of [ZLibraryApi]: resolving the file link and
// streaming the file to disk or into a pending MediaStore entry.
// Split out of `zlibrary_api.dart` (item 7, step 4, final) as a mixin
// in the same library, `on ZLibraryApiBase` (plus `ZLibrarySearch`
// since the book-page download arm), so it can use the base
// class's private HTTP helpers (`_dio`, `_headers`, `_base`,
// `_fromError`) and session fields directly. The hash-resolution
// helper (`resolveEapiHash`) lives in the base class because both
// this mixin (`_resolveDownloadLink`) and the search mixin
// (`getBookInfo`) call it. A mixin in a separate library could not
// see those privates without changing the public interface (which
// the six test fakes implement).
part of 'zlibrary_api.dart';

/// 书页那条腿的一发结果（见 [ZLibraryDownloads._fetchPageDlAttempt]）。
class BookPageDlAttempt {
  /// 试的那个书页地址。失败文案里只以掩码写法出现（见 `url_mask.dart`）。
  final String href;

  /// `found` = 页面里有站内 `/dl/` 地址；`no-link` = 页面取到了但没有
  /// 按钮；`wall` = 这一页本身站在浏览器校验后面；`failed` = 别的失败
  /// （404、不是书页、解析不出来）。
  final String outcome;

  /// `wall` / `failed` 时插件那句短错误。
  final String? error;

  /// `found` 时那个 `/dl/` 地址（已过 [_ownHtmlDownloadLink] 的站内 /
  /// https / `/dl/` 三条校验）。
  final String? dlLink;

  /// 读回来的那一页里到底有没有这个书的 id。`false` 意味着那一发拿回的
  /// 不是这本书的书页（首页），此时「这一页没有按钮」对这本书毫无意义，
  /// 下一个地址形状还得试。
  final bool? pageHasBookId;

  /// 这一发真的动用了一次浏览器读页（[ZLibraryApi.wallHtmlFetcher] 被调
  /// 用过）。书页腿拿它数封顶几发 WebView——失败的那几发同样开了窗，不能
  /// 不算。
  final bool browserRead;

  const BookPageDlAttempt({
    required this.href,
    required this.outcome,
    this.error,
    this.dlLink,
    this.pageHasBookId,
    this.browserRead = false,
  });
}

/// Download methods for [ZLibraryApi].
///
/// `ZLibrarySearch` is in the constraint because the last-resort arm
/// reads the book's own HTML page (`getBookInfoFromHtmlPage`) to find
/// the `/dl/` button when the card carried no address at all.
mixin ZLibraryDownloads on ZLibraryApiBase, ZLibrarySearch {
  // ── Download ───────────────────────────────────────────────────────

  /// Sidecar file holding the resume validator for [savePath].
  /// Delegates to the shared [DownloadRange.metaPathFor] (phase 5):
  /// the twin engine (`ResumableDownloader.metaPathFor`, the external
  /// path) used to carry the identical one-liner.
  static String metaPathFor(String savePath) =>
      DownloadRange.metaPathFor(savePath);

  /// Total size from a `Content-Range: bytes */N` header — the form a
  /// 416 answer carries — or null when the header is absent or does
  /// not parse. Delegates to the shared [DownloadRange.parseContentRangeTotal]
  /// (O10): the twin engine (`ResumableDownloader`, the external path)
  /// uses the same parser, so the two stay in step.
  static int? _totalFromContentRange(String? contentRange) =>
      DownloadRange.parseContentRangeTotal(contentRange);

  /// True when [bytes] (the start of a body) look like an ebook file
  /// the app can open: epub/zip start with `PK`, PDF with `%PDF`, MOBI
  /// carries `BOOKMOBI` at offset 60. A file too short to check, or one
  /// in a format with another magic (fb2, djvu, txt, rtf), also answers
  /// true — this is the accept fast path of the finish-line check, not an
  /// allow-list: see [_badBookFileHead] for why rejecting a book this
  /// function does not recognise would cost a fully transferred file.
  static bool looksLikeBook(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
      return true; // PK — epub / zip.
    }
    if (bytes.length >= 5 &&
        bytes[0] == 0x25 && // %
        bytes[1] == 0x50 && // P
        bytes[2] == 0x44 && // D
        bytes[3] == 0x46) {
      return true; // %PDF (the 5th byte is the version digit).
    }
    if (bytes.length >= 68) {
      const marker = 'BOOKMOBI';
      for (var i = 0; i < marker.length; i++) {
        if (bytes[60 + i] != marker.codeUnitAt(i)) return false;
      }
      return true;
    }
    // Too short to check, or an unknown format: do not reject.
    return true;
  }

  /// True when [bytes] (the start of a body) look like an HTML document.
  /// Delegates to the shared [DownloadRange.looksLikeHtml] (O10) — the
  /// same rule as `ResumableDownloader.looksLikeHtml` (the external
  /// path), so the two engines cannot drift: a fresh body that is really
  /// an HTML page (mislabelled Content-Type) must not touch the disk.
  static bool looksLikeHtml(List<int> bytes) =>
      DownloadRange.looksLikeHtml(bytes);

  /// Resolve the file link via `/eapi/book/{id}/{hash}/file` and stream
  /// the file to [savePath]. Throws on failure (the app catches it and
  /// re-checks the download quota via getProfile).
  ///
  /// Link safety: an absolute link must be `https`; anything else is
  /// refused outright. The session Cookie is only sent to our own domain —
  /// a cross-domain link (e.g. a storage CDN) is fetched without it, and
  /// redirects are followed manually for the same reason (Dio would
  /// re-send the Cookie header to whatever host a 302 points at).
  ///
  /// `onProgress` receives `(received, total)`; `cancelToken` is the
  /// caller's Dio token (the app checks `isCancelled` itself).
  ///
  /// [title] is the book title, used only when the stored hash turns
  /// out to be a webpage short hash: the file endpoint rejects it
  /// with "Invalid hash", and the real hash is then resolved with
  /// [resolveEapiHash] (see getBookInfo).
  ///
  /// [htmlDownloadLink] is the site's own download address for the
  /// book (`/dl/{token}`, absolute) — the one attribute an HTML card
  /// carries that needs no eapi hash at all. It is the last resort
  /// when the hash route is unusable: since 2026-11-24 the search
  /// endpoint that [resolveEapiHash] depended on answers `Access
  /// denied` and no page on the site exposes a 6-character hash (see
  /// [getBookInfoFromHtmlPage]), so a book that arrived through HTML
  /// has no hash to resolve and `/dl/…` is the only address left.
  /// The token is self-contained, so this path also skips the file
  /// endpoint's quota/redirect handling — which is why it is tried
  /// only after that endpoint has actually failed, never first.
  ///
  /// [bookPageHref] is the same card's own page address (`/book/{hash}/…`)
  /// — the URL the site itself published for this book, so it is the
  /// first shape the page arm reads. Cards from the recommendation
  /// shelf carry it too; a task restored from a file name does not.
  Future<void> downloadBook(
    String bookId,
    String hash,
    String savePath, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    String? title,
    PendingDownloadWriter? pendingWriter,
    String? htmlDownloadLink,
    String? bookPageHref,
  }) async {
    var link = await _resolveDownloadLink(
      bookId,
      hash,
      title: title,
      htmlDownloadLink: htmlDownloadLink,
      bookPageHref: bookPageHref,
    );
    var headers = Map<String, String>.from(_headers);
    if (Uri.parse(link).host != Uri.parse(_base).host) {
      headers.remove('Cookie');
    }
    var wallSolved = false;
    var solveAnsweredOk = false;
    for (var hop = 0; hop < 5; hop++) {
      final Response<ResponseBody> res;
      try {
        res = await _downloadOnce(
          link,
          savePath,
          headers,
          onProgress: onProgress,
          cancelToken: cancelToken,
          pendingWriter: pendingWriter,
        );
      } on DownloadHtmlException catch (e) {
        // 墙这一支（2026-11-24 真机第二份报告钉下来的）：`/dl/{token}`
        // 本身就站在浏览器校验后面——三种请求头策略都在**同一跳**拿到
        // `HTTP 503 + text/html`，一次重定向都没发生。所以带不带 cookie、
        // 带不带 Referer 根本不参与结果，唯一能改变答复的是先去过一次
        // 墙，再把同一发请求重发。求解本身在 App 层（[wallCookieRefresh]，
        // 插件打不开 WebView），这里只保证：一次下载最多解一次、解完只
        // 重试这一跳，非墙的 HTML 错误绝不进这条路（别拿一本书的失败
        // 去开 WebView，也别把重发变成循环）。
        final solve = wallCookieRefresh;
        if (!e.isWall ||
            wallSolved ||
            solve == null ||
            // 只解本站的墙。别的主机回 503 时绝不能求解：App 那一腿要
            // 把 `remix_userid` / `remix_userkey` 装进 WebView 的 cookie
            // jar，而 jar 是按 URL 的 host 写的——照着一条 CDN 地址去解，
            // 等于把登录会话送给第三方域。何况那也不是这堵墙。
            Uri.parse(link).host != Uri.parse(_base).host) {
          throw _withWallLegNote(e, wallSolved, solveAnsweredOk);
        }
        wallSolved = true;
        final solved = await solve(link);
        solveAnsweredOk = solved;
        // 第 9 轮的取路：浏览器在这一跳被交予的地址优先于「cookie 回灌进
        // Dio 再重发 `/dl/`」。真机那份报告证明后半条链在设备上不通——
        // 过墙的凭证跟着那个 WebView 走，Dio 重发拿回来的还是校验页。
        final captured = takeDlFileUrl(link);
        if (captured != null) {
          link = captured;
        } else if (!solved) {
          throw _withWallLegNote(e, wallSolved, solveAnsweredOk);
        }
        // 重新取头：回灌的墙 cookie 和它那套 User-Agent 都在 `_headers`
        // 里（cf_clearance 是绑 UA 的），沿用求解前那份旧副本等于白解。
        // 抓到的是第三方 CDN 直链时整个 `Cookie` 头摘掉——那上面的凭证
        // 是签名参数，不是会话。
        headers = Map<String, String>.from(_headers);
        if (Uri.parse(link).host != Uri.parse(_base).host) {
          headers.remove('Cookie');
        }
        continue;
      }
      final code = res.statusCode ?? 0;
      if (code != 301 &&
          code != 302 &&
          code != 303 &&
          code != 307 &&
          code != 308) {
        return;
      }
      final location = res.headers.value(HttpHeaders.locationHeader);
      if (location == null || location.isEmpty) {
        // 掩码后的地址是判据：`/dl/…` 与 CDN 跳的失败形态完全不同。
        throw StateError(
          'download redirect without location '
          '(HTTP ${res.statusCode}, ${_maskUrl(link)})',
        );
      }
      final next = Uri.parse(link).resolveUri(Uri.parse(location));
      if (next.scheme != 'https') {
        throw StateError('download redirect to non-https URL');
      }
      link = next.toString();
      if (next.host != Uri.parse(_base).host) {
        headers = Map<String, String>.from(headers)..remove('Cookie');
      }
    }
    throw StateError('too many download redirects');
  }

  /// 解过墙的失败要多说一句。
  ///
  /// 同一句 `HTTP 503 + text/html` 在「压根没解」和「解完了这一跳还是校验
  /// 页」之间是两种相反的修法，光看原文分不出来。只说这一件事：不带 cookie
  /// 名字、不带 URL、不带页题——那些是诊断层的话，不该长在错误文案里。
  /// 没跑过求解的路保持原文，不给它加「未过墙」这种没跑过的判据。
  DownloadHtmlException _withWallLegNote(
    DownloadHtmlException error,
    bool wallSolved,
    bool solveAnsweredOk,
  ) {
    if (!wallSolved) return error;
    return DownloadHtmlException(
      '${error.message} '
      '(${solveAnsweredOk ? "已过墙，这一跳仍未给出文件" : "过墙未成"})',
      isWall: error.isWall,
    );
  }

  /// Download one hop of [link] into [savePath], resuming from the bytes
  /// already on disk when the server honours Range.
  ///
  /// A 3xx writes nothing (the caller follows the Location); a 200
  /// restarts the file from zero (the server ignored Range); a 206
  /// appends. A 416 (our partial file is longer than the server's file)
  /// truncates and restarts once — unless Content-Range says the
  /// remote file is exactly as big as our partial, in which case the
  /// download already finished and the file is kept (O5). Progress
  /// reports the true position (resumed bytes + bytes received in this
  /// request) against the full size, so a resumed download does not
  /// restart the progress bar.
  ///
  /// Resume safety (S2): the validator (ETag, else Last-Modified) seen
  /// when the partial file was started is stored next to it
  /// (`<part>.meta`, see [metaPathFor]) and sent back as `If-Range`.
  /// If the remote file changed, the server answers 200 with the full
  /// body and we restart from zero instead of appending to a stale
  /// prefix (which would produce a corrupt book). A partial with no
  /// recorded validator — a mirror that sends neither ETag nor
  /// Last-Modified, or a file left by a pre-1.6.0 build — still sends
  /// its Range and keeps the bytes already on disk; the offset is then
  /// proven by the answer instead, see [DownloadRange.canAppendPartialRange].
  /// A 206 whose `Content-Range` starts anywhere but [start] restarts —
  /// a server (or proxy) that answers a different range would otherwise
  /// get its bytes appended at the wrong offset. Same contract as the
  /// external path (`ResumableDownloader`); the two engines must stay in
  /// step.
  Future<Response<ResponseBody>> _downloadOnce(
    String link,
    String savePath,
    Map<String, String> headers, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    PendingDownloadWriter? pendingWriter,
  }) async {
    final file = File(savePath);
    final meta = File(metaPathFor(savePath));
    final start = pendingWriter != null
        ? pendingWriter.bytesWritten
        : await file.exists()
            ? await file.length()
            : 0;
    // Absent whenever the mirror sent neither ETag nor Last-Modified (or
    // the partial predates the sidecar). It only ever decorates the
    // request now: dropping the resume offset because it was missing used
    // to re-transfer a whole book on every pause / retry / cold start,
    // because a pending entry can only be recreated - that is what the
    // 206 trust check below replaced (2026-11-15 perf).
    final validator =
        start > 0 ? await DownloadRange.readValidator(meta) : null;
    // A pending entry cannot be truncated, only recreated: if the resume
    // offset ever is dropped, reset the writer before the request.
    if (pendingWriter != null &&
        start == 0 &&
        pendingWriter.bytesWritten > 0) {
      if (!await pendingWriter.reset()) {
        throw StateError('cannot restart the pending MediaStore entry');
      }
    }
    // Phase 5: the resume header build is shared with the twin engine
    // (Range / If-Range / Accept-Encoding identity, O13) so the three
    // rules land once.
    final reqHeaders = DownloadRange.resumeHeaders(
      headers,
      start,
      validator: validator,
    );
    final res = await _dio.get<ResponseBody>(
      link,
      options: Options(
        headers: reqHeaders,
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(seconds: 300),
        followRedirects: false,
        // 503/513 也要读答复：dio 默认的 validateStatus 会在它们上面
        // 直接抛，正文（那张浏览器校验页）永远到不了手里，于是真机上
        // `/dl/` 撞墙只留下一句 `HTTP 503`——求解这条腿（downloadBook 里
        // 的 isWall 分支）根本没有触发机会。放进来以后由下面的显式分支
        // 处理，绝不会被当成文件写盘。
        validateStatus: (status) =>
            status != null &&
            (status < 400 ||
                (status == 416 && start > 0) ||
                status == 503 ||
                status == 513),
      ),
      cancelToken: cancelToken,
    );
    final code = res.statusCode ?? 0;
    if (code >= 300 && code < 400) {
      // Redirect body is empty; drain it so the connection is released.
      await res.data?.stream.drain<void>();
      return res;
    }
    // 这两个状态码在这个站点上就是浏览器校验（`_looksLikeChallengePage`
    // 的调用方早就按同样的规则处理 HTML 页）。对文件请求而言它永远不是
    // 文件，所以在这里当场拒掉：读出头是为了让文案说得出它是哪一张页，
    // 不写盘、不续传。
    if (code == 503 || code == 513) {
      final head = await _readHeadBytes(res.data?.stream);
      throw DownloadHtmlException(
        'download is behind the browser check '
        '(HTTP $code, content-type '
        '${res.headers.value(HttpHeaders.contentTypeHeader) ?? 'none'}, '
        '${head.length} B head, ${_maskUrl(link)}) — needs a wall '
        'solve, not a retry',
        isWall: true,
      );
    }
    if (code == 416 && start > 0) {
      await res.data?.stream.drain<void>();
      // A 416 means the resume offset is at or past the end of the
      // remote file. When Content-Range reports the remote size is
      // exactly our partial (N == start), the download already
      // finished — the process was killed after the stream ended but
      // before the .meta was removed — so keep the file and finish
      // normally instead of throwing it away and re-downloading the
      // whole book (O5). Only N < start (or an unparsable header)
      // resets and restarts from zero.
      final remoteSize =
          _totalFromContentRange(res.headers.value('content-range'));
      if (remoteSize != null && remoteSize == start) {
        // Same finished-file header check as a normal completion (the
        // earlier attempt may have been killed before it ran). The
        // pending-writer path has no file to check here.
        if (pendingWriter == null && await _badBookFileHead(file)) {
          if (await meta.exists()) await meta.delete();
          throw DownloadHtmlException(
            'download finished but the file is not the book it claims to '
            'be — the mirror served a challenge or error page',
          );
        }
        if (await meta.exists()) await meta.delete();
        return res;
      }
      // Recreate the partial empty; the recursive call then restarts
      // with start == 0 and no Range header. The reset-vs-truncate rule
      // lives in DownloadRange so both engines stay in step.
      if (!await DownloadRange.discardPartialBytes(file, pendingWriter)) {
        throw StateError('cannot restart the pending MediaStore entry');
      }
      if (await meta.exists()) await meta.delete();
      return _downloadOnce(
        link,
        savePath,
        headers,
        onProgress: onProgress,
        cancelToken: cancelToken,
        pendingWriter: pendingWriter,
      );
    }
    // A 206 must continue exactly where our partial file ends. A server
    // (or proxy) that answers a different range would otherwise get its
    // bytes appended at the wrong offset: a silently corrupt book.
    if (code == 206 && start > 0) {
      final cr = res.headers.value('content-range');
      // O10: the Content-Range rule is shared with the twin engine
      // (`ResumableDownloader`), so a rule change lands once.
      if (!DownloadRange.canAppendPartialRange(
        cr,
        start,
        ifRangeAccepted: validator != null,
      )) {
        await res.data?.stream.drain<void>();
        if (!await DownloadRange.discardPartialBytes(file, pendingWriter)) {
          throw StateError('cannot restart the pending MediaStore entry');
        }
        if (await meta.exists()) await meta.delete();
        return _downloadOnce(
          link,
          savePath,
          headers,
          onProgress: onProgress,
          cancelToken: cancelToken,
          pendingWriter: pendingWriter,
        );
      }
    }
    final contentLength = int.tryParse(
          res.headers.value(HttpHeaders.contentLengthHeader) ?? '',
        ) ??
        -1;
    final resumed = code == 206 && start > 0;
    final total = resumed ? start + contentLength : contentLength;

    // An HTML answer to a file request is a challenge/error page, not a
    // book: saving it would produce a tiny, "successfully downloaded"
    // corrupted file. Reject before anything is written.
    final contentType =
        res.headers.value(HttpHeaders.contentTypeHeader) ?? '';
    if (contentType.toLowerCase().contains('text/html')) {
      // 头几 KB 必须先读出来再丢：墙不丢标记的话，它和一张错误页在
      // 屏上长一样，而这两件事的下一步完全相反（一张得去求解，一张
      // 求了也没用）。旧的写法直接 drain，于是 2026-11-24 真机上那三次
      // `/dl/` 的 503 只能报成一句"answered an HTML page"。
      final head = await _readHeadBytes(res.data?.stream);
      final wall = ZLibraryApiBase.isWallAnswer(code, _decodeHead(head));
      throw DownloadHtmlException(
        wall
            ? 'download is behind the browser check '
                  '(HTTP $code, content-type $contentType, '
                  '${_maskUrl(link)}) — needs a wall solve, not a retry'
            : 'download answered an HTML page '
                  '(HTTP $code, content-type $contentType, '
                  '${_maskUrl(link)}) — the mirror is likely serving a '
                  'challenge or error page instead of the file',
        isWall: wall,
      );
    }

    // The validator for this body, for the next resume: ETag, else
    // Last-Modified. Recorded on a fresh (non-resumed) download only.
    // Phase 5: shared extraction (was inline, identical in the twin).
    final newValidator =
        DownloadRange.validatorFromResponse(res.headers);

    // With a pending writer there is no file sink at all; bytes go
    // through the writer's buffered channel. When the server answered
    // 200 to a resume request (restarting the body), the pending entry
    // must be recreated — appending would corrupt the file.
    IOSink? sink;
    var received = resumed ? start : 0;
    var firstChunk = true;
    try {
      await for (final chunk in res.data!.stream) {
        if (firstChunk) {
          firstChunk = false;
          // A fresh body that is really an HTML page (mislabelled
          // Content-Type) must not touch the disk.
          if (!resumed && looksLikeHtml(chunk)) {
            final wall = ZLibraryApiBase.isWallAnswer(
              code,
              _decodeHead(chunk),
            );
            throw DownloadHtmlException(
              wall
                  ? 'download body is the browser check page '
                        '(HTTP $code, content-type $contentType, '
                        '${chunk.length} B head, ${_maskUrl(link)}) '
                        '— needs a wall solve, not a retry'
                  : 'download body is an HTML page, not a book file '
                        '(HTTP $code, content-type $contentType, '
                        '${chunk.length} B head, ${_maskUrl(link)})',
              isWall: wall,
            );
          }
          if (!resumed) {
            // New file: remember its validator for future resumes.
            if (newValidator != null) {
              await meta.writeAsString(newValidator);
            } else if (await meta.exists()) {
              await meta.delete();
            }
          }
          if (pendingWriter == null) {
            sink = file.openWrite(
              mode: resumed ? FileMode.append : FileMode.write,
            );
          } else if (!resumed && start > 0) {
            // The server restarted the body (200 to a resume request):
            // recreate the pending entry — appending would corrupt it.
            if (!await pendingWriter.reset()) {
              throw StateError(
                  'cannot restart the pending MediaStore entry');
            }
            received = 0;
          }
        }
        if (sink != null) {
          sink.add(chunk);
        } else {
          await pendingWriter!.add(chunk);
        }
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } finally {
      await sink?.close();
    }
    // Length check: a stream that ends early (connection dropped and
    // silently closed by a proxy, truncated CDN answer) must not count
    // as a finished download.
    if (total > 0 && received < total) {
      throw StateError(
        'download truncated: received $received of $total bytes',
      );
    }
    // File-header check: a finished download must not be an HTML
    // challenge/error page wearing a file name. The rule used to be
    // positive ("the head must be PK, %PDF or BOOKMOBI"), which rejected
    // every format whose magic is not one of those three — fb2 (`<?xml`),
    // djvu (`AT&TFORM`), txt, rtf — *after* the whole book had already
    // been transferred, and the retry then restarted from zero: a
    // download that never finishes, however fast the line is. The
    // negative form catches what this guard is for, plus the signature of
    // the format the file claims to be - and nothing else. A stitched
    // resume is already caught by the Content-Range check above. The
    // partial file
    // is kept so a retry can resume; the validator is dropped so the
    // retry restarts from zero instead of appending to the bad prefix.
    // The pending writer path has no file to check here — its bytes are
    // checked when the entry is published.
    if (pendingWriter == null && await _badBookFileHead(file)) {
      if (await meta.exists()) await meta.delete();
      throw DownloadHtmlException(
        'download finished but the file is not the book it claims to be '
        '(HTML challenge/error page, or the wrong signature for its '
        'extension; ${_maskUrl(link)}) — the mirror did not serve '
        'the file',
      );
    }
    if (await meta.exists()) {
      // The download finished: the validator is no longer needed. The
      // file is about to be renamed away by the caller, so keeping the
      // sidecar would only orphan it next to a path that no longer
      // exists. A later download of the same book rewrites it.
      await meta.delete();
    }
    return res;
  }


  /// The first few KB of an HTML answer, for the wall check only.
  ///
  /// `break` out of the `await for` cancels dio's subscription, which
  /// tears the connection down instead of pulling a whole mirror page
  /// through the phone (`stream.drain` reads to the end — fine for a
  /// 2 KB 302 body, not for a 200 KB HTML answer). 4 KB is well past
  /// where DDoS-Guard / Cloudflare put their markers (`<title>Checking
  /// your browser…</title>`, `ddos-guard`, `cf-challenge`).
  Future<List<int>> _readHeadBytes(
    Stream<List<int>>? stream, {
    int max = 4096,
  }) async {
    if (stream == null) return const [];
    final head = <int>[];
    try {
      await for (final chunk in stream) {
        if (head.length < max) head.addAll(chunk);
        if (head.length >= max) break;
      }
    } on Object {
      // 弃流时的取消异常不是证据：头已经拿到了。
    }
    return head;
  }

  static String _decodeHead(List<int> bytes) =>
      utf8.decode(bytes, allowMalformed: true);

  /// True when the finished file at [file] must not be recorded as a
  /// book: an HTML challenge/error page under any name, or bytes that do
  /// not carry the signature of the extension the book was saved as.
  ///
  /// The rule is deliberately negative. The old one was "the head must be
  /// one of three magics", which rejected fb2 (`<?xml`), djvu
  /// (`AT&TFORM`), txt, rtf and everything else it did not know *after*
  /// the whole book had been transferred — and the retry restarted from
  /// zero, so the download never finished. A false rejection is therefore
  /// the expensive error here: an extension with no definite signature is
  /// never checked, and an unreadable file passes (the length check in
  /// [_downloadOnce] is the guard for that).
  static Future<bool> _badBookFileHead(File file) async {
    List<int> head;
    try {
      final raf = await file.open();
      try {
        head = await raf.read(512);
      } finally {
        await raf.close();
      }
    } on FileSystemException {
      return false;
    }
    if (looksLikeBook(head)) return false; // the fast path for known books
    if (DownloadRange.looksLikeHtml(head)) return true;
    return _signatureMismatch(file.path, head);
  }

  /// True when the file named [path] claims a format whose signature is
  /// definite and [head] does not carry it. Formats with no fixed magic
  /// (txt, rtf, chm, lit, htmlz, an extensionless save path) answer false:
  /// there is nothing to check them against.
  static bool _signatureMismatch(String path, List<int> head) {
    switch (_extensionOf(path)) {
      case 'epub':
      case 'zip':
      case 'cbz':
        return !_startsWithAscii(head, 'PK');
      case 'pdf':
        return !_startsWithAscii(head, '%PDF');
      case 'mobi':
      case 'azw':
      case 'azw3':
        // looksLikeBook already tested the PK/%PDF magics, so reach for
        // the container marker at offset 60.
        return !_startsWithAsciiAt(head, 60, 'BOOKMOBI');
      case 'fb2':
        return !_startsWithAny(head, const ['<?xml', '<FictionBook']);
      case 'djvu':
      case 'djv':
        return !_startsWithAscii(head, 'AT&TFORM');
      default:
        return false;
    }
  }

  /// Lower-case extension of [path] without the dot, or '' when the file
  /// name has none.
  static String _extensionOf(String path) {
    final slash = path.replaceAll(r'\', '/').lastIndexOf('/');
    final name = slash < 0 ? path : path.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    return dot < 1 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static bool _startsWithAscii(List<int> head, String text) =>
      _startsWithAsciiAt(head, 0, text);

  static bool _startsWithAsciiAt(List<int> head, int at, String text) {
    if (head.length < at + text.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (head[at + i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  static bool _startsWithAny(List<int> head, List<String> prefixes) {
    for (final p in prefixes) {
      if (_startsWithAscii(head, p)) return true;
    }
    return false;
  }

  Future<String> _resolveDownloadLink(
    String bookId,
    String hash, {
    String? title,
    String? htmlDownloadLink,
    String? bookPageHref,
  }) async {
    // 详情页加载已把短 hash→真 hash 的映射落库（见 getBookInfo 的
    // resolveCacheWrite）：下载直接用真 hash，省掉"短 hash 必失败的
    // 第一次取链接 + 按标题解析"。
    final mapped = await ZLibraryApiBase.resolveCacheLookup?.call(
      bookId,
      hash,
    );
    final effective = (mapped == null || mapped.isEmpty) ? hash : mapped;
    try {
      return await _fetchDownloadLink(bookId, effective);
    } on StateError catch (e) {
      final message = e.message.toString();
      // Same short-hash trap as getBookInfo: the file endpoint
      // rejects a webpage short hash with "Invalid hash". Resolve the
      // real hash once and retry; anything else is rethrown unchanged.
      if (title != null &&
          title.isNotEmpty &&
          ZLibraryApiBase._isInvalidHashError(message)) {
        final resolved = await resolveEapiHash(bookId, title);
        if (resolved != null && resolved != effective) {
          ZLibraryApiBase.resolveCacheWrite?.call(bookId, hash, resolved);
          return _fetchDownloadLink(bookId, resolved);
        }
      }
      // The hash route is unusable (short hash, nothing left that can
      // resolve it) — only that specific failure may fall through to
      // the page's own /dl/ address. A quota, auth or server error
      // must stay an error: the caller re-checks the quota on throw,
      // and quietly switching channels would hide it.
      if (ZLibraryApiBase._isInvalidHashError(message)) {
        // 卡片带过来就用卡片的；什么都没带（2026-11-24 第三份报告）则
        // 现造书页地址去取那一枚 `/dl/`——没有它，这本书就真的无路可走。
        final link = _ownHtmlDownloadLink(htmlDownloadLink);
        if (link != null) return link;
        final attempts = await bookPageDlAttempts(
          bookId,
          hash,
          href: bookPageHref,
          title: title,
          solveWall: true,
        );
        for (final attempt in attempts) {
          final found = attempt.dlLink;
          if (found != null) return found;
        }
        // 书页这条腿走完了却没交出地址：那句 `Invalid hash` 只说明 eapi
        // 拒了这个 hash，真正的问题是这一腿为什么空手。把逐候选的答复
        // 拼上去（掩码地址 + outcome + 过墙现场），三种原因三种修法，
        // 不能再让它们挤成同一句话。
        throw StateError('$message (${_pageArmSummary(attempts)})');
      }
      rethrow;
    }
  }

  /// 书页那条腿的逐候选答复，一行写完，只带掩码后的地址和答复种类。
  ///
  /// 这两样留下是因为它们本身就是判据：`→ wall` / `→ no-link` / `→ failed`
  /// 三种原因修法相反，而真机报告靠这一句就能定位到是哪一发地址形状。
  /// 探针层往这里加的现场（cookie 名字、浏览器落点、页题、字节数）已经不
  /// 在了——那是本地分支上的诊断功能，不是下载的一部分。
  String _pageArmSummary(List<BookPageDlAttempt> attempts) {
    if (attempts.isEmpty) return '书页没试出去（没有可用地址）';
    final parts = attempts
        .map((a) => '${_maskUrl(a.href)} → ${a.outcome}')
        .join(' | ');
    return '书页: $parts';
  }

  /// [link] when it is a usable download address for this instance:
  /// `https`, on the API's own host, under `/dl/`. Anything else —
  /// a relative path, another host, a non-https scheme, a null — is
  /// refused, so a page can never redirect the session cookie to a
  /// third party through this branch.
  String? _ownHtmlDownloadLink(String? link) {
    final raw = link?.trim() ?? '';
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !uri.hasScheme ||
        uri.scheme != 'https' ||
        uri.host != Uri.parse(_base).host) {
      return null;
    }
    if (!uri.path.startsWith('/dl/')) return null;
    return raw;
  }

  /// 书页地址候选。
  ///
  /// 2026-11-24 那份真页面（`/book/QOPq7W2BRX/给仰望者的星空史….html`，
  /// 5.8 MB）把形状钉死了：整页 241 个 `/book/` 链接全是
  /// `/book/{hash}/{标题}.html`，`/book/{id}/{hash}/` 一次都没出现——
  /// 站里没有这条路由。所以第 8 轮真机报告里"浏览器读回来的是首页"不是
  /// hash 错了，也不是没登录，是**那一发地址本身不存在**（旧代码把它当
  /// 第一候选，于是每一本短 hash 的书都只能读到首页）。
  ///
  /// 顺序：① 卡片自己的 href（站写的，slug 一定对）；② 用标题现造的
  /// `/book/{hash}/{slug}.html`（同一形状，slug 由 [_bookPageSlug] 按
  /// 真页面的 58 组 title/slug 对照推出来的规则拼）；③ `/book/{hash}/`；
  /// ④⑤ 旧的 id 形状留作末位——它们在这条链上已被证明只会弹回首页，
  /// 但探针过去报过 `wall`，不能就此连试都不试。
  List<String> bookPageCandidates(
    String bookId,
    String hash, {
    String? href,
    String? title,
  }) {
    final out = <String>[];
    void add(String url) {
      final value = url.trim();
      if (value.isEmpty || out.contains(value)) return;
      out.add(value);
    }

    final known = href?.trim() ?? '';
    if (known.isNotEmpty) {
      add(known.startsWith('http') ? known : '$_base$known');
    }
    final short = hash.trim();
    if (short.isNotEmpty) {
      final slug = _bookPageSlug(title);
      if (slug != null) add('$_base/book/$short/$slug.html');
      add('$_base/book/$short/');
      add('$_base/book/$bookId/$short/');
    }
    add('$_base/book/$bookId/');
    return out;
  }

  /// 标题 → 站点 URL 里那段 slug。规则来自同一份真页面里 58 组
  /// `(z-cover title, href slug)` 对照：空白折成 `-`、其余标点整个丢掉
  /// （`：`、`《》`、`·` 都消失）、字母小写（`BBC` → `bbc`）、连字符合并。
  /// 58 组里 57 组逐字符相同；剩下那组是书名后来被编辑过，slug 没跟着改。
  /// 认不出可用 slug（空、或被过滤干净）时返回 null，让上一级跳过这一发。
  String? _bookPageSlug(String? title) {
    final raw = title?.trim() ?? '';
    if (raw.isEmpty) return null;
    final kept = RegExp(
      '[^0-9A-Za-z\\u4e00-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af-]',
    );
    final dashed = raw
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(kept, '')
        .replaceAll(RegExp('-+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '')
        .toLowerCase();
    if (dashed.isEmpty) return null;
    return Uri.encodeComponent(dashed);
  }

  /// 抓一发书页、从里面挑出站内可见的 `/dl/` 地址。[solveWall] 决定书页
  /// 自己撞在浏览器校验后面时要不要请 App 解一次（下载解，读页探针不解：
  /// 后者的产出是证据，不是让用户替它过墙）。[allowBrowserRead] 是那一发
  /// WebView 的额度（见 [bookPageDlAttempts] 的封顶）。
  Future<BookPageDlAttempt> _fetchPageDlAttempt(
    String href, {
    required bool solveWall,
    required String bookId,
    bool allowBrowserRead = true,
  }) async {
    try {
      var res = await getBookInfoFromHtmlPage(href);
      if (!res.success &&
          solveWall &&
          ZLibraryApiBase.isWallErrorText(res.error)) {
        // 书页站在墙后。下载这一侧先要**那一页的 HTML**，不要"墙
        // cookie 进 Dio 再重发"那条链：按钮就在浏览器渲染出来的页面里，
        // 而那条链还得靠墙 cookie 的名字恰好落在 App 的白名单里。
        final fetcher = allowBrowserRead ? wallHtmlFetcher : null;
        final html = await fetcher?.call(href);
        final fromHtml = html == null || html.isEmpty
            ? null
            : _ownHtmlDownloadLink(
                dlLinkFromPageHtml(html, href, bookId: bookId));
        if (fromHtml != null) {
          return BookPageDlAttempt(
            href: href,
            outcome: 'found',
            dlLink: fromHtml,
            browserRead: fetcher != null,
          );
        }
        if (html != null && html.isNotEmpty) {
          // 浏览器把这一页读回来了，里面没有可见按钮。但"读回来的是首页"
          // 和"读到的确实是这本书、只是没有按钮"是两件相反的事（真机报告
          // 给的是前者：页题是 `Z-Library – the w…`），所以这里不把它当成
          // 对这本书的定论，下一个地址形状还得试。
          return BookPageDlAttempt(
            href: href,
            outcome: 'no-link',
            pageHasBookId: html.contains(bookId),
            browserRead: fetcher != null,
          );
        }
        final solve = wallCookieRefresh;
        if (solve != null && await solve(href)) {
          res = await getBookInfoFromHtmlPage(href);
        }
      }
      final link = _ownHtmlDownloadLink(res.data?.downloadPath);
      if (link != null) {
        return BookPageDlAttempt(href: href, outcome: 'found', dlLink: link);
      }
      if (!res.success) {
        return BookPageDlAttempt(
          href: href,
          outcome: ZLibraryApiBase.isWallErrorText(res.error)
              ? 'wall'
              : 'failed',
          error: res.error,
        );
      }
      return BookPageDlAttempt(href: href, outcome: 'no-link');
    } on Object catch (e) {
      // 书页那条腿是"额外一试"：它自己炸了不能顶掉调用方原本要报的错
      // （无效哈希那句），否则用户看到的就不是下载失败的原因了。
      return BookPageDlAttempt(
        href: href,
        outcome: 'failed',
        error: '${e.runtimeType}',
      );
    }
  }

  /// 书页那条腿的逐候选结果。探针拿它说话（[solveWall] 默认关：探针绝不
  /// 弹验证页），下载也走它——报出来的和跑掉的是同一套判断。
  ///
  /// 早停三种：拿到地址（后面几发没意义）、**撞墙**（墙是当前会话的状态，
  /// 不是这本书的属性，换一页还是同一道校验）、**读到了这本书的书页但里
  /// 面没有按钮**。`failed`（404、不是书页）和「读回来的页面里连这本书的
  /// id 都没有」——也就是被弹回首页——都换下一个地址形状再试。
  ///
  /// 浏览器读页全书封顶 [maxBrowserPageReads] 发：形状再多，每开一次
  /// WebView 都是几秒的白屏，而第 8 轮的教训是"读回来的页面对不对"本身
  /// 就有机器可读的判据（[BookPageDlAttempt.pageHasBookId]），不需要拿
  /// 五发去赌。
  Future<List<BookPageDlAttempt>> bookPageDlAttempts(
    String bookId,
    String hash, {
    String? href,
    String? title,
    bool solveWall = false,
    int maxBrowserPageReads = 2,
  }) async {
    final candidates = bookPageCandidates(
      bookId,
      hash,
      href: href,
      title: title,
    );
    final attempts = <BookPageDlAttempt>[];
    var browserReads = 0;
    for (final candidate in candidates) {
      final attempt = await _fetchPageDlAttempt(
        candidate,
        solveWall: solveWall,
        bookId: bookId,
        allowBrowserRead: browserReads < maxBrowserPageReads,
      );
      attempts.add(attempt);
      if (attempt.browserRead) browserReads++;
      // `no-link` 只有在**那一页确实是这本书**时才是定论。第 8 轮真机
      // 报告里那一发读回来的是首页（页题 `Z-Library – the w…`、页面里
      // 连 id 都没有），它对这本书什么都没说；把它当定论就等于让后面的
      // 地址形状永远没机会跑——而真页面证明的正是这件事：旧代码第一发
      // 用的是站里根本不存在的 `/book/{id}/{hash}/`。
      final definite = attempt.outcome != 'failed' &&
          !(attempt.outcome == 'no-link' && attempt.pageHasBookId == false);
      if (definite) break;
    }
    return attempts;
  }

  /// Resolve the file link for [bookId]/[hash].
  ///
  /// The `/eapi/book/{id}/{hash}/file` endpoint answers either JSON
  /// (a `downloadLink` / `download_url` / …) or the file itself.
  /// The file case must not be read as a String (S3): a tens-of-MB
  /// PDF decoded as UTF-8 spikes memory and can OOM a low-end phone,
  /// and the bytes are then downloaded a second time anyway. The
  /// response is streamed instead: a JSON Content-Type is read and
  /// parsed, anything else is cancelled after at most the first chunk
  /// of body (the probe only needs headers) and the endpoint is then
  /// treated as the file URL itself.
  Future<String> _fetchDownloadLink(String bookId, String hash) async {
    final path = '/eapi/book/$bookId/$hash/file';
    // Header-only probe: when this endpoint turns out to stream the
    // file itself, the same URL is requested again for the actual
    // download (with its own Range / If-Range), so the token below
    // is cancelled instead of the body being read.
    final probe = CancelToken();
    try {
      final res = await _dio.get<ResponseBody>(
        '$_base$path',
        options: Options(
          headers: _headers,
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          // Read the answer instead of letting a 4xx throw: the file
          // endpoint reports a rejected hash as `400` + a JSON body
          // (`{"success":0,"error":"无效哈希"}`, site-measured
          // 2026-11-24), and with the default `validateStatus` dio
          // raises before the body is read — the stream in
          // `DioException.response` is spent by then, so the caller
          // only ever saw the generic lookup failure and none of the
          // invalid-hash branches (`resolveEapiHash` retry, the
          // `/dl/…` fallback) could fire. Accepting every status
          // routes the body through the JSON branch below, which
          // turns it into a `StateError` carrying the server's own
          // text. A non-JSON error page still ends in the HTTP-status
          // `StateError` at the bottom of this method.
        ),
        cancelToken: probe,
      );
      final contentType =
          (res.headers.value(HttpHeaders.contentTypeHeader) ?? '')
              .toLowerCase();
      if (contentType.contains('json')) {
        final body = await utf8.decoder.bind(res.data!.stream).join();
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          final link = _findLink(decoded);
          if (link != null && link.isNotEmpty) {
            final uri = Uri.tryParse(link);
            if (uri != null && uri.hasScheme && uri.scheme != 'https') {
              throw StateError('download link is not https');
            }
            // Resolve relative links against the base instead of
            // string-concatenating: a bare path without a leading `/`
            // and a `//host/path` link were both handled wrong.
            return Uri.parse(_base).resolve(link).toString();
          }
          final err = (decoded['error'] ?? decoded['message'])?.toString();
          throw StateError(err ?? 'no download link in file response');
        }
        throw StateError('no download link in file response');
      }
      // Not JSON: the endpoint itself streams the file — but only if
      // the payload really is a binary/ebook response. An HTML answer
      // is a wall or error page: treating it as a "file stream" makes
      // downloadBook fetch the same page a second time and save the
      // HTML as the book.
      //
      // Answer from the headers alone, and abort the response
      // instead of draining it: `drain` reads a stream to its end,
      // so the lookup transferred the whole book over the wire
      // before the download asked for it again (2026-11-15 perf).
      // Cancelling tears the connection down right there (dio pipes
      // an adapter stream as soon as the answer arrives, so at most
      // the chunk already in flight lands), and the download still
      // gets to send Range / If-Range - a reused probe stream (a
      // plain 200, no Range asked for) could never resume a paused
      // book.
      probe.cancel('download link lookup is header-only');
      if (res.statusCode == 200 &&
          !contentType.contains('text/html')) {
        return '$_base$path';
      }
      throw StateError(
        'file endpoint answered HTTP ${res.statusCode} '
        '(${contentType.isEmpty ? 'no content-type' : contentType}) '
        'instead of JSON or a file stream',
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      throw StateError(_fromError(
        e,
      ).error ?? 'download link lookup failed');
    }
  }

  static String? _findLink(Map<String, dynamic> json) {
    for (final key in const [
      'downloadLink',
      'download_url',
      'downloadUrl',
      'url',
      'link',
      'file',
    ]) {
      final v = json[key];
      if (v is String && v.isNotEmpty) return v;
      if (v is Map<String, dynamic>) {
        final nested = _findLink(v);
        if (nested != null) return nested;
      }
    }
    final data = json['data'];
    if (data is Map<String, dynamic>) return _findLink(data);
    return null;
  }
}
