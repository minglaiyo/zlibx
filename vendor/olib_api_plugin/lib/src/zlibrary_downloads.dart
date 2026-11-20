// Downloads domain of [ZLibraryApi]: resolving the file link and
// streaming the file to disk or into a pending MediaStore entry.
// Split out of `zlibrary_api.dart` (item 7, step 4, final) as a mixin
// in the same library, `on ZLibraryApiBase`, so it can use the base
// class's private HTTP helpers (`_dio`, `_headers`, `_base`,
// `_fromError`) and session fields directly. The hash-resolution
// helper (`resolveEapiHash`) lives in the base class because both
// this mixin (`_resolveDownloadLink`) and the search mixin
// (`getBookInfo`) call it. A mixin in a separate library could not
// see those privates without changing the public interface (which
// the six test fakes implement).
part of 'zlibrary_api.dart';

/// Download methods for [ZLibraryApi].
mixin ZLibraryDownloads on ZLibraryApiBase {
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
  Future<void> downloadBook(
    String bookId,
    String hash,
    String savePath, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    String? title,
    PendingDownloadWriter? pendingWriter,
  }) async {
    var link = await _resolveDownloadLink(bookId, hash, title: title);
    var headers = Map<String, String>.from(_headers);
    if (Uri.parse(link).host != Uri.parse(_base).host) {
      headers.remove('Cookie');
    }
    for (var hop = 0; hop < 5; hop++) {
      final res = await _downloadOnce(
        link,
        savePath,
        headers,
        onProgress: onProgress,
        cancelToken: cancelToken,
        pendingWriter: pendingWriter,
      );
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
        throw StateError('download redirect without location');
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
        validateStatus: (status) =>
            status != null && (status < 400 || (status == 416 && start > 0)),
      ),
      cancelToken: cancelToken,
    );
    final code = res.statusCode ?? 0;
    if (code >= 300 && code < 400) {
      // Redirect body is empty; drain it so the connection is released.
      await res.data?.stream.drain<void>();
      return res;
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
      if (pendingWriter != null) {
        // Recreate the pending entry empty; the recursive call then
        // restarts with start == 0 and no Range header.
        if (!await pendingWriter.reset()) {
          throw StateError('cannot restart the pending MediaStore entry');
        }
      } else {
        await file.writeAsBytes(const []);
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
        if (pendingWriter != null) {
          if (!await pendingWriter.reset()) {
            throw StateError('cannot restart the pending MediaStore entry');
          }
        } else {
          await file.writeAsBytes(const []);
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
      await res.data?.stream.drain<void>();
      throw DownloadHtmlException(
        'download answered an HTML page '
        '(HTTP $code, content-type $contentType) — the mirror is likely '
        'serving a challenge or error page instead of the file',
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
            throw DownloadHtmlException(
              'download body is an HTML page, not a book file',
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
        'extension) — the mirror did not serve the file',
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
      // Same short-hash trap as getBookInfo: the file endpoint
      // rejects a webpage short hash with "Invalid hash". Resolve the
      // real hash once and retry; anything else is rethrown unchanged.
      if (title != null &&
          title.isNotEmpty &&
          ZLibraryApiBase._isInvalidHashError(e.message.toString())) {
        final resolved = await resolveEapiHash(bookId, title);
        if (resolved != null && resolved != effective) {
          ZLibraryApiBase.resolveCacheWrite?.call(bookId, hash, resolved);
          return _fetchDownloadLink(bookId, resolved);
        }
      }
      rethrow;
    }
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
