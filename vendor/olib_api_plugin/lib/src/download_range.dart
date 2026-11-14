/// Shared pure helpers for the two download engines (O10): the app's
/// [`ResumableDownloader`] (external-source path) and the plugin's
/// `ZLibraryDownloads._downloadOnce` (Z-Library path). Keeping the HTML
/// sniff and the Content-Range parsing in one place means an O5 /
/// integrity fix only needs to land once — the two engines must stay in
/// step, and a duplicated rule is a drift waiting to happen.
library;

import 'dart:convert';

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
}
