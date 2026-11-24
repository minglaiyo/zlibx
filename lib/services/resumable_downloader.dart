// Single-stream resumable file download with integrity checks.
//
// Extracted from DownloadNotifier._downloadResumable. The external-source
// path (LibGen / Anna's Archive / LAN transfer) used to lack two checks
// that the Z-Library plugin path already had, so a challenge or error page
// could be saved as a "successfully downloaded" book:
//
//  * an HTML answer to a file request is rejected before anything is
//    written (by Content-Type, and by sniffing the first bytes when the
//    server mislabels it);
//  * a stream that ends before Content-Length is reported as truncated
//    (the partial file is kept so the next attempt resumes from it).
//
// Resume safety: the validator (ETag, else Last-Modified) seen when the
// partial file was started is stored next to it (`<part>.meta`) and sent
// back as `If-Range`. If the remote file changed, the server answers 200
// with the full body and we restart from zero instead of appending to a
// stale prefix (which would produce a corrupt book).
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../utils/diagnostics.dart';


/// The server answered with something that is not the requested file
/// (challenge / error page). Never retried automatically.
class DownloadContentException implements Exception {
  final String message;
  const DownloadContentException(this.message);
  @override
  String toString() => message;
}

/// The stream ended before the advertised length. The partial file is
/// kept so a retry can resume.
class DownloadTruncatedException implements Exception {
  final int received;
  final int expected;
  const DownloadTruncatedException(this.received, this.expected);
  @override
  String toString() =>
      'download truncated: received $received of $expected bytes';
}

class ResumableDownloader {
  ResumableDownloader._();

  /// Sidecar file holding the resume validator for [savePath].
  /// Delegates to the shared [DownloadRange.metaPathFor] (phase 5):
  /// the twin engine (`ZLibraryDownloads.metaPathFor`) used to carry
  /// the identical one-liner.
  static String metaPathFor(String savePath) =>
      DownloadRange.metaPathFor(savePath);

  /// True when [bytes] (the start of a body) look like an HTML document.
  /// Delegates to the shared [DownloadRange.looksLikeHtml] (O10) so the
  /// two engines cannot drift.
  static bool looksLikeHtml(List<int> bytes) =>
      DownloadRange.looksLikeHtml(bytes);

  /// Total size from a `Content-Range: bytes */N` header — the form a
  /// 416 answer carries — or null when the header is absent or does
  /// not parse. Shared with the twin engine (`_downloadOnce` in the
  /// vendor plugin) through [DownloadRange.parseContentRangeTotal]
  /// (O10): the two engines must stay in step.
  static int? _totalFromContentRange(String? contentRange) =>
      DownloadRange.parseContentRangeTotal(contentRange);

  /// Downloads [url] into [savePath], resuming from bytes already on disk
  /// when the server honours Range. See the library comment for the
  /// integrity rules. Throws [DownloadContentException],
  /// [DownloadTruncatedException] or a [DioException].
  ///
  /// When [pendingWriter] is given, bytes stream into its pending
  /// MediaStore entry instead of [savePath]; [savePath] is then only the
  /// key for the `.meta` validator and `.pending.json` sidecars.
  static Future<void> download(
    Dio dio,
    String url,
    String savePath, {
    Map<String, String>? headers,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    PendingDownloadWriter? pendingWriter,
  }) async {
    // At most one forced restart (after a 416): bounded, never recursive.
    for (var attempt = 0; attempt < 2; attempt++) {
      final restarted = await _attempt(
        dio,
        url,
        savePath,
        headers: headers,
        onProgress: onProgress,
        cancelToken: cancelToken,
        pendingWriter: pendingWriter,
      );
      if (!restarted) return;
    }
    throw const DownloadContentException(
      'server keeps rejecting the resume range (HTTP 416)',
    );
  }

  /// Returns true when the caller must retry from scratch (416).
  static Future<bool> _attempt(
    Dio dio,
    String url,
    String savePath, {
    Map<String, String>? headers,
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
    // Only decorates the request now (see the twin rule in
    // `ZLibraryDownloads._downloadOnce`): a mirror with neither ETag nor
    // Last-Modified has no validator to record, and its partials must
    // still resume instead of starting the book over.
    final validator = start > 0
        ? await DownloadRange.readValidator(meta)
        : null;
    // A pending entry cannot be truncated, only recreated: if the resume
    // offset ever is dropped, reset the writer before the request.
    if (pendingWriter != null && start == 0 && pendingWriter.bytesWritten > 0) {
      if (!await pendingWriter.reset()) {
        throw const DownloadContentException(
          'cannot recreate the pending MediaStore entry',
        );
      }
    }

    // Phase 5: the resume header build is shared with the twin engine
    // (Range / If-Range / Accept-Encoding identity, O13) so the three
    // rules land once.
    final reqHeaders = DownloadRange.resumeHeaders(
      headers ?? const {},
      start,
      validator: validator,
    );

    final res = await dio.get<ResponseBody>(
      url,
      options: Options(
        headers: reqHeaders,
        responseType: ResponseType.stream,
        followRedirects: true,
        validateStatus: (status) =>
            status != null &&
            ((status >= 200 && status < 300) || (status == 416 && start > 0)),
      ),
      cancelToken: cancelToken,
    );
    final code = res.statusCode ?? 0;
    if (code == 416) {
      await res.data?.stream.drain<void>();
      // A 416 means the resume offset is at or past the end of the
      // remote file. When Content-Range reports the remote size is
      // exactly our partial (N == start), the download already
      // finished — the process was killed after the stream ended but
      // before the .meta was removed — so keep the file and finish
      // normally instead of throwing it away and re-downloading the
      // whole book (O5). Only N < start (or an unparsable header)
      // resets and restarts from zero.
      final remoteSize = _totalFromContentRange(
        res.headers.value('content-range'),
      );
      if (remoteSize != null && remoteSize == start) {
        if (await meta.exists()) await meta.delete();
        return false;
      }
      if (!await DownloadRange.discardPartialBytes(file, pendingWriter)) {
        throw const DownloadContentException(
          'cannot recreate the pending MediaStore entry',
        );
      }
      if (await meta.exists()) await meta.delete();
      return true;
    }

    // A 206 must continue exactly where our partial file ends. A server
    // (or proxy) that answers a different range would otherwise get its
    // bytes appended at the wrong offset: a silently corrupt book.
    if (code == 206 && start > 0) {
      final cr = res.headers.value('content-range');
      // O10: the Content-Range rule is shared with the twin engine (the
      // vendor plugin's `_downloadOnce`), so a rule change lands once.
      if (!DownloadRange.canAppendPartialRange(
        cr,
        start,
        ifRangeAccepted: validator != null,
      )) {
        await res.data?.stream.drain<void>();
        if (!await DownloadRange.discardPartialBytes(file, pendingWriter)) {
          throw const DownloadContentException(
            'cannot recreate the pending MediaStore entry',
          );
        }
        if (await meta.exists()) await meta.delete();
        return true;
      }
    }

    final contentType = (res.headers.value(HttpHeaders.contentTypeHeader) ?? '')
        .toLowerCase();
    if (contentType.contains('text/html')) {
      await res.data?.stream.drain<void>();
      throw DownloadContentException(
        'download answered an HTML page (HTTP $code) — the source is '
        'likely serving a challenge or error page instead of the file',
      );
    }

    final contentLength =
        int.tryParse(
          res.headers.value(HttpHeaders.contentLengthHeader) ?? '',
        ) ??
        -1;
    final resumed = code == 206 && start > 0;
    final base = resumed ? start : 0;
    final total = contentLength >= 0 ? base + contentLength : -1;

    // Phase 5: shared extraction (was inline, identical in the twin).
    final newValidator = DownloadRange.validatorFromResponse(res.headers);

    final body = res.data;
    if (body == null) {
      // The server sent no body at all. Treat it as an empty download
      // (same end state as an empty stream below): clear a stale prefix
      // on a fresh download, report truncation when a length was
      // advertised, and drop the validator.
      if (!resumed) {
        if (!await DownloadRange.discardPartialBytes(file, pendingWriter)) {
          throw const DownloadContentException(
            'cannot recreate the pending MediaStore entry',
          );
        }
      }
      if (total > 0 && base < total) {
        throw DownloadTruncatedException(base, total);
      }
      if (await meta.exists()) await meta.delete();
      return false;
    }

    if (pendingWriter != null && !resumed && start > 0) {
      // The server restarted the body (200 to a resume request):
      // recreate the pending entry — appending would corrupt it.
      if (!await pendingWriter.reset()) {
        throw const DownloadContentException(
          'cannot recreate the pending MediaStore entry',
        );
      }
    }

    IOSink? sink;
    var received = base;
    var firstChunk = true;
    // M2: backpressure for the .part path. IOSink.add is fire-and-
    // forget: a fast network outruns a slow disk and the buffer grows
    // without bound (the pending MediaStore path already awaits with
    // an 8-batch window). Flush every 4 MB so the loop waits for the
    // disk instead of buffering the whole book in memory.
    var flushed = base;
    const flushThreshold = 4 * 1024 * 1024;
    // L4: a close failure must not mask an in-flight loop error (the
    // finally would replace it), and a raw FileSystemException must
    // not be the task error either. Record it, log the cause, and fail
    // with a storage error only when the loop itself succeeded.
    Object? closeError;
    try {
      await for (final chunk in body.stream) {
        if (firstChunk) {
          firstChunk = false;
          // A fresh body that is really an HTML page (mislabelled
          // Content-Type) must not touch the disk.
          if (looksLikeHtml(chunk)) {
            if (!resumed) {
              throw const DownloadContentException(
                'download body is an HTML page, not a book file',
              );
            }
            // M3: a resumed 206 body that is really HTML — the server
            // or proxy is serving a page at the resume offset (the
            // Content-Range check only proves the offset, not the
            // content). Discard the partial and restart from zero,
            // like the 416 / Content-Range paths. The fresh attempt
            // throws if the server still serves HTML.
            if (!await DownloadRange.discardPartialBytes(
              file,
              pendingWriter,
            )) {
              throw const DownloadContentException(
                'cannot recreate the pending MediaStore entry',
              );
            }
            if (await meta.exists()) await meta.delete();
            return true;
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
          }
        }
        if (sink != null) {
          sink.add(chunk);
        } else {
          await pendingWriter!.add(chunk);
        }
        received += chunk.length;
        if (sink != null && received - flushed >= flushThreshold) {
          await sink.flush();
          flushed = received;
        }
        onProgress?.call(received, total);
      }
    } finally {
      try {
        await sink?.close();
      } on Object catch (e) {
        closeError = e;
        logIgnored('resumable_downloader_close', e);
      }
    }
    if (closeError != null) {
      throw StateError(
        'could not finish writing the download file: $closeError',
      );
    }
    if (firstChunk && !resumed) {
      // Empty body: make sure a stale partial prefix does not survive.
      if (!await DownloadRange.discardPartialBytes(file, pendingWriter)) {
        throw const DownloadContentException(
          'cannot recreate the pending MediaStore entry',
        );
      }
    }

    if (total > 0 && received < total) {
      throw DownloadTruncatedException(received, total);
    }
    if (await meta.exists()) await meta.delete();
    return false;
  }
}
