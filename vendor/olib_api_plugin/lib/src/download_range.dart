/// Shared pure helpers for the two download engines (O10): the app's
/// [`ResumableDownloader`] (external-source path) and the plugin's
/// `ZLibraryDownloads._downloadOnce` (Z-Library path). Keeping the HTML
/// sniff and the Content-Range parsing in one place means an O5 /
/// integrity fix only needs to land once — the two engines must stay in
/// step, and a duplicated rule is a drift waiting to happen.
///
/// Phase 5 adds the remaining duplicated rules: the sidecar path, the
/// validator read, the resume request-header build and the ETag /
/// Last-Modified extraction.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'zlibrary_api.dart';

class DownloadRange {
  DownloadRange._();

  /// True when [bytes] (the start of a body) look like an HTML document.
  /// A challenge / error page must not be saved as a book. Same rule in
  /// both engines.
  static bool looksLikeHtml(List<int> bytes) {
    if (bytes.isEmpty) return false;
    final head = utf8
        .decode(bytes.take(512).toList(), allowMalformed: true)
        .replaceFirst('\uFEFF', '')
        .trimLeft()
        .toLowerCase();
    return head.startsWith('<!doctype html') ||
        head.startsWith('<html') ||
        head.startsWith('<head') ||
        head.startsWith('<body');
  }

  /// Lower-case extension of [path] without the dot, or `''` when the
  /// file name has none. A trailing `.part` is stripped first, so a
  /// staged download (`Book - 123.epub.part`) reports `epub`, not
  /// `part`: the old vendor-local copy of this rule did not strip it,
  /// so the finish-line signature check silently never ran in
  /// production (the tests saved without `.part` and never caught it).
  static String extensionOf(String path) {
    final slash = path.replaceAll(r'\', '/').lastIndexOf('/');
    var name = slash < 0 ? path : path.substring(slash + 1);
    if (name.toLowerCase().endsWith('.part')) {
      name = name.substring(0, name.length - 5);
    }
    final dot = name.lastIndexOf('.');
    return dot < 1 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// True when [head] (the first bytes of a file) carries the magic of
  /// [extension] — plan item 8: epub/docx/zip/cbz start with `PK`,
  /// pdf with `%PDF`, fb2 with `<` (after one leading UTF-8 BOM),
  /// mobi/azw/azw3 carry `BOOKMOBI` at offset 60, djvu/djv start with
  /// `AT&TFORM`. An extension with no definite magic (txt, rtf, chm,
  /// lit, htmlz, an extensionless save path) always passes: there is
  /// nothing to check it against, and a false rejection costs a fully
  /// transferred book.
  ///
  /// A head too short to prove a mismatch passes — a first chunk can be
  /// a few bytes long, and a short resume prefix (a real MOBI's first
  /// 30 bytes carry no `BOOKMOBI` yet) must not be rejected for what it
  /// cannot show. Only content that is provably not the book is
  /// rejected; the length check is the guard for a file that is simply
  /// too short.
  static bool magicMatchesExtension(List<int> head, String extension) {
    bool startsWithAt(String text, int at) {
      if (head.length < at + text.length) return true;
      for (var i = 0; i < text.length; i++) {
        if (head[at + i] != text.codeUnitAt(i)) return false;
      }
      return true;
    }
    // One leading UTF-8 BOM is not content: an FB2 file may carry one
    // before its `<`. (Binary formats never carry one, so only the FB2
    // check looks past it.)
    final textStart =
        head.length >= 3 &&
            head[0] == 0xEF &&
            head[1] == 0xBB &&
            head[2] == 0xBF
        ? 3
        : 0;

    switch (extension) {
      case 'epub':
      case 'docx':
      case 'zip':
      case 'cbz':
        return startsWithAt('PK', 0);
      case 'pdf':
        return startsWithAt('%PDF', 0);
      case 'fb2':
        return startsWithAt('<', textStart);
      case 'mobi':
      case 'azw':
      case 'azw3':
        return startsWithAt('BOOKMOBI', 60);
      case 'djvu':
      case 'djv':
        return startsWithAt('AT&TFORM', 0);
      default:
        return true;
    }
  }

  /// Parses the start offset from a
  /// `Content-Range: bytes start-end/total` header, or null when the
  /// header is absent or unparseable. Used by the 206 branch to verify
  /// the server continued exactly where the partial file ends.
  static int? parseContentRangeStart(String? contentRange) {
    if (contentRange == null) return null;
    final m = RegExp(r'^\s*bytes\s+(\d+)-', caseSensitive: false)
        .firstMatch(contentRange);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// True when a `206` answer to our `Range: bytes=[start]-` may be
  /// appended to the bytes already on disk.
  ///
  /// There are two possible proofs. `Content-Range` is the direct one:
  /// a server that echoes a range starting anywhere other than [start] -
  /// or a proxy that mangles the header - must not get its bytes stitched
  /// onto the partial, or two different files end up spliced at one byte
  /// offset. When the header is absent or unparsable the offset is still
  /// trustworthy if [ifRangeAccepted] is set: we sent an `If-Range`
  /// validator and the server answered 206 rather than falling back to
  /// the full body, which means it served the same file it described on
  /// the first request. With neither proof the caller restarts from zero.
  ///
  /// Shared by both engines (O10) so a resume-safety rule lands once.
  static bool canAppendPartialRange(
    String? contentRange,
    int start, {
    required bool ifRangeAccepted,
  }) {
    final parsedStart = parseContentRangeStart(contentRange);
    if (parsedStart != null) return parsedStart == start;
    return ifRangeAccepted;
  }

  /// Parses the total from a `Content-Range: bytes */total` header — the
  /// form a 416 answer uses — or null when absent / unparseable. Used by
  /// the 416 branch (O5) to tell "the .part is already complete"
  /// (total == start) from "the remote file shrank" (total < start).
  static int? parseContentRangeTotal(String? contentRange) {
    if (contentRange == null) return null;
    final m = RegExp(r'bytes\s+\*/\s*(\d+)', caseSensitive: false)
        .firstMatch(contentRange);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

// ──────────────────────────────────────────────────────────────────
// Phase 5: the remaining rules that used to live twice, once per
// engine. Each one below existed verbatim in both
// `ZLibraryDownloads` and `ResumableDownloader` — a fix had to land
// twice, and a missed copy was a drift.
// ──────────────────────────────────────────────────────────────────

/// Sidecar file holding the resume validator for [savePath]
/// (`<part>.meta`). Both engines used the identical one-liner.
static String metaPathFor(String savePath) => '$savePath.meta';

/// Reads the resume validator recorded next to [meta] (`<part>.meta`).
/// Returns null when there is none, it is empty, or it cannot be read.
/// Was `_readValidator` in both engines, byte-for-byte identical.
static Future<String?> readValidator(File meta) async {
  try {
    if (!await meta.exists()) return null;
    final v = (await meta.readAsString()).trim();
    return v.isEmpty ? null : v;
  } on FileSystemException {
    return null;
  }
}

/// Request headers for resuming [savePath] at [start]:
///
///  * `Accept-Encoding: identity` — file downloads want raw bytes (O13):
///    a gzipped answer makes Content-Length disagree with the received
///    bytes, skewing progress and the truncation check;
///  * `Range: bytes=[start]-` when there is something to resume;
///  * `If-Range` only when a real [validator] exists — an
///    unrecognised value is answered with the full body, losing the
///    resume either way.
///
/// Returns a copy; [headers] is not mutated. Was built inline in both
/// engines with the same three rules.
static Map<String, String> resumeHeaders(
  Map<String, String> headers,
  int start, {
  required String? validator,
}) {
  final req = Map<String, String>.from(headers);
  req['Accept-Encoding'] = 'identity';
  if (start > 0) {
    req['Range'] = 'bytes=$start-';
    if (validator != null) req['If-Range'] = validator;
  }
  return req;
}

/// The validator for this body, for the next resume: ETag, else
/// Last-Modified. Recorded on a fresh (non-resumed) download only.
/// Was extracted inline in both engines.
static String? validatorFromResponse(Headers headers) =>
    headers.value(HttpHeaders.etagHeader) ??
    headers.value(HttpHeaders.lastModifiedHeader);

/// Discards the partial bytes of a download so the next attempt starts
/// from zero: recreates the pending MediaStore entry when
/// [pendingWriter] is given — a pending entry cannot be truncated,
/// only recreated — else truncates [file]. Returns false when the
/// pending entry cannot be recreated; the caller raises its own
/// engine-specific error.
///
/// Shared by both engines: this reset-vs-truncate rule existed
/// verbatim in six places across `ResumableDownloader._attempt` and
/// `ZLibraryDownloads._downloadOnce` — a missed copy on one side was a
/// drift waiting to happen.
static Future<bool> discardPartialBytes(
  File file,
  PendingDownloadWriter? pendingWriter,
) async {
  if (pendingWriter != null) return pendingWriter.reset();
  await file.writeAsBytes(const []);
  return true;
}
}
