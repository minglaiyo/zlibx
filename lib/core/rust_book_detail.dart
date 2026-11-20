import 'package:flutter/foundation.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart' as zl;
import '../lib.dart' as frb_api;
import '../models.dart' as frb;
import '../utils/app_log.dart';
import '../utils/diagnostics.dart';
import 'rust_init.dart';

/// Phase 3: wires the Rust-backed book detail metadata parser into the
/// vendor plugin's `bookDetailParseOverride` hook. Same architecture
/// as rust_fulltext.dart / rust_article.dart: lazy FRB init (never
/// blocks startup, silently falls back to Dart when the bridge is
/// unavailable), and a model mapping layer to the hand-written vendor
/// models.
///
/// Call [injectRustBookDetailParser] once from `main()`.
void injectRustBookDetailParser() {
  zl.bookDetailParseOverride = _rustParseBookDetail;
}

Future<zl.BookDetailMetadata> _rustParseBookDetail(String html) async {
  try {
    await ensureRustBridge();
  } on Object catch (e) {
    if (kDebugMode) {
      logIgnored('frb_book_detail_init', e);
    }
    zl.bookDetailParseOverride = null;
    return zl.parseBookDetailProperties(html);
  }
  final meta = await frb_api.parseBookDetailProperties(html: html);
  if (kDebugMode) {
    AppLog.debug(
      'book detail parsed via Rust: '
      'volume=${meta.volume != null} isbn=${meta.isbn13 != null} '
      'ipfs=${meta.ipfsCid != null} ratings=${meta.ratingInterest != null}',
      tag: 'FRB',
    );
  }
  return _mapBookDetailMetadata(meta);
}

zl.BookDetailMetadata _mapBookDetailMetadata(frb.BookDetailMetadata m) {
  return zl.BookDetailMetadata(
    volume: m.volume,
    isbn10: m.isbn10,
    isbn13: m.isbn13,
    ipfsCid: m.ipfsCid,
    // FRB renames the field ipfsCidBlake2B (case); vendor is ipfsCidBlake2b.
    ipfsCidBlake2b: m.ipfsCidBlake2B,
    ratingInterest: m.ratingInterest,
    ratingQuality: m.ratingQuality,
  );
}
