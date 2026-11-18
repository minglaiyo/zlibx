import 'package:flutter/foundation.dart';
import '../lib.dart' as frb_api;
import '../models.dart' as frb;
import 'annas_archive.dart' as zl;
import 'rust_init.dart';

/// Phase 4: wires the Rust-backed Anna's Archive parsers into the
/// static `ArchiveParsing` hooks. Same architecture as the other
/// rust_* bridges: lazy FRB init (never blocks startup, silently
/// falls back to Dart when the bridge is unavailable).
///
/// Only the two heavy HTML parsers are hooked; the light string/URL
/// helpers (cleanText / formatFromInfo / md5FromLink / resolveUrl /
/// buildSearchUrl / challenge checks) stay Dart — their cost is
/// microseconds, below the FFI round-trip.
///
/// Call [injectRustAnnasParsers] once from `main()`.
void injectRustAnnasParsers() {
  zl.ArchiveParsing.searchResultsParseOverride = _rustAnnasSearch;
  zl.ArchiveParsing.bookDetailsParseOverride = _rustAnnasDetails;
}

Future<void> _ensureInit() async {
  await ensureRustBridge();
}

void _unregister() {
  if (kDebugMode) {
    debugPrint('[FRB] annas bridge init failed, falling back to Dart');
  }
  zl.ArchiveParsing.searchResultsParseOverride = null;
  zl.ArchiveParsing.bookDetailsParseOverride = null;
}

Future<List<zl.ArchiveBook>> _rustAnnasSearch(
  String html,
  String baseUrl,
  String fileType,
) async {
  try {
    await _ensureInit();
  } on Object {
    _unregister();
    return zl.ArchiveParsing.parseSearchResults(
      html,
      baseUrl: baseUrl,
      fileType: fileType,
    );
  }
  final books = await frb_api.parseAnnasSearchResults(
    html: html,
    baseUrl: baseUrl,
    fileType: fileType,
  );
  if (kDebugMode) {
    debugPrint('[FRB] annas search parsed via Rust: ${books.length} books');
  }
  return books.map(_mapArchiveBook).toList();
}

Future<zl.ArchiveBookDetails?> _rustAnnasDetails(
  String html,
  String url,
  String baseUrl,
) async {
  try {
    await _ensureInit();
  } on Object {
    _unregister();
    return zl.ArchiveParsing.parseBookDetails(html, url: url, baseUrl: baseUrl);
  }
  final details = await frb_api.parseAnnasBookDetails(
    html: html,
    url: url,
    baseUrl: baseUrl,
  );
  if (details == null) return null;
  if (kDebugMode) {
    debugPrint('[FRB] annas detail parsed via Rust: ${details.title}');
  }
  return _mapArchiveDetails(details);
}

zl.ArchiveBook _mapArchiveBook(frb.ArchiveBook b) {
  return zl.ArchiveBook(
    title: b.title,
    author: b.author,
    thumbnail: b.thumbnail,
    link: b.link,
    md5: b.md5,
    publisher: b.publisher,
    info: b.info,
  );
}

zl.ArchiveBookDetails _mapArchiveDetails(frb.ArchiveBookDetails d) {
  return zl.ArchiveBookDetails(
    title: d.title,
    author: d.author,
    thumbnail: d.thumbnail,
    link: d.link,
    md5: d.md5,
    publisher: d.publisher,
    info: d.info,
    description: d.description,
    slowDownloadUrl: d.slowDownloadUrl,
  );
}
