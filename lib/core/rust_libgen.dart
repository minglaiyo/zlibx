import 'package:flutter/foundation.dart';
import '../lib.dart' as frb_api;
import '../models.dart' as frb;
import '../services/annas_models.dart' as am;
import '../services/external_search.dart' as ext;
import '../services/libgen_service.dart' as lg;
import '../services/open_library.dart' as ol;
import 'rust_init.dart';

/// Phase 4: wires the Rust-backed Library Genesis / Open Library
/// parsers into their hooks in external_search.dart, libgen_service.dart
/// and open_library.dart.
///
/// Failure contract: when the bridge is unavailable (init fails) the
/// hooks UN-REGISTER and RETHROW — each call site catches, falls back
/// to the Dart parser, and re-arms naturally on the next call because
/// the hook is null there. When the bridge works, a parse error inside
/// Rust also propagates as an exception (same as the Dart parser
/// throwing), so "try the next mirror" behavior is unchanged.
///
/// Call [injectRustExternalParsers] once from `main()`.
void injectRustExternalParsers() {
  ext.libgenResultsParseOverride = _rustLibgenResults;
  lg.libgenAdsPageParseOverride = _rustLibgenAds;
  ol.openLibraryTrendingParseOverride = _rustOpenLibraryTrending;
}

Future<void> _ensureInit() async {
  await ensureRustBridge();
}

void _unregister(String tag, Object error) {
  if (kDebugMode) {
    debugPrint('[FRB] $tag bridge failed, falling back to Dart: $error');
  }
  resetRustBridge();
  ext.libgenResultsParseOverride = null;
  lg.libgenAdsPageParseOverride = null;
  ol.openLibraryTrendingParseOverride = null;
}

Future<List<am.BookData>> _rustLibgenResults(
  String html,
  String baseUrl,
) async {
  try {
    await _ensureInit();
  } on Object catch (e) {
    _unregister('libgen results', e);
    rethrow;
  }
  final books = await frb_api.parseLibgenResults(html: html, baseUrl: baseUrl);
  if (kDebugMode) {
    debugPrint('[FRB] libgen results parsed via Rust: ${books.length} books');
  }
  return books.map(_mapLibgenBook).toList();
}

Future<am.BookInfoData?> _rustLibgenAds(
  String html,
  String baseUrl,
  String url,
) async {
  try {
    await _ensureInit();
  } on Object catch (e) {
    _unregister('libgen ads', e);
    rethrow;
  }
  final info = await frb_api.parseLibgenAdsPage(
    html: html,
    baseUrl: baseUrl,
    url: url,
  );
  if (info == null) return null;
  if (kDebugMode) {
    debugPrint('[FRB] libgen ads parsed via Rust: ${info.title}');
  }
  return am.BookInfoData(
    title: info.title,
    author: info.author,
    thumbnail: info.thumbnail,
    publisher: info.publisher,
    info: info.info,
    link: info.link,
    md5: info.md5,
    format: info.format,
    mirror: info.mirror,
    description: info.description,
  );
}

Future<List<ol.TrendingBookData>> _rustOpenLibraryTrending(String html) async {
  try {
    await _ensureInit();
  } on Object catch (e) {
    _unregister('openlibrary trending', e);
    rethrow;
  }
  final books = await frb_api.parseOpenLibraryTrending(html: html);
  if (kDebugMode) {
    debugPrint('[FRB] openlibrary trending parsed via Rust: ${books.length}');
  }
  return books
      .map((t) => ol.TrendingBookData(title: t.title, thumbnail: t.thumbnail))
      .toList();
}

am.BookData _mapLibgenBook(frb.LibgenBookData b) {
  return am.BookData(
    title: b.title,
    author: b.author,
    thumbnail: b.thumbnail,
    link: b.link,
    md5: b.md5,
    publisher: b.publisher,
    info: b.info,
  );
}
