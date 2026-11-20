import 'package:flutter/foundation.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart' as zl;
import '../lib.dart' as frb_api;
import '../models.dart' as frb;
import '../utils/app_log.dart';
import '../utils/diagnostics.dart';
import 'rust_init.dart';

/// JSON sink: wires the Rust-backed eapi book-list parser into the vendor
/// plugin's `booksParseOverride` hook.
///
/// Same architecture as rust_fulltext.dart / rust_booklists.dart:
/// - FRB runs `parse_books_json` on the Rust thread pool, replacing the
///   Dart `_booksOf` + `Book.fromJson` decode for every search / popular /
///   recent / saved / downloaded feed.
/// - The bridge initializes lazily on the FIRST parsed feed, so startup is
///   never blocked and a missing `.so` falls back to Dart silently.
/// - On any bridge failure the hook un-registers itself and parsing falls
///   back to the Dart implementation — behavior identical either way
///   (test/services/json_books_test.dart is the contract for both).
///
/// Call [injectRustBooksParser] once from `main()`.
void injectRustBooksParser() {
  zl.booksParseOverride = _rustParseBooks;
}

Future<List<zl.Book>> _rustParseBooks(String json) async {
  try {
    await ensureRustBridge();
  } on Object catch (e) {
    if (kDebugMode) {
      logIgnored('frb_books_init', e);
    }
    resetRustBridge();
    zl.booksParseOverride = null;
    return zl.ZLibraryApiBase.fallbackBooksOf(json);
  }
  // The bridge is up, but the parse call itself can still fail (malformed
  // JSON that slips past serde, FRB serialization error, Rust panic caught
  // by the bridge). Catch runtime failures too so a single bad response
  // never kills the whole feed — un-register and fall back to Dart.
  try {
    final books = await frb_api.parseBooksJson(json: json);
    AppLog.debug('books parsed via Rust: ${books.length} rows', tag: 'FRB');
    return books.map(_mapBook).toList();
  } on Object catch (e) {
    logIgnored('frb_books_runtime', e);
    zl.booksParseOverride = null;
    return zl.ZLibraryApiBase.fallbackBooksOf(json);
  }
}

// ──────────────────────────────────────────────────────────────────
// FRB-generated Book → hand-written vendor Book. Field-name deltas:
// extension_ (Dart reserved word), ipfsCidBlake2B vs ipfsCidBlake2b.
// ──────────────────────────────────────────────────────────────────

zl.Book _mapBook(frb.Book b) {
  return zl.Book(
    id: b.id,
    title: b.title,
    hash: b.hash,
    href: b.href,
    author: b.author,
    cover: b.cover,
    description: b.description,
    publisher: b.publisher,
    year: b.year,
    language: b.language,
    categories: b.categories,
    pages: b.pages,
    series: b.series,
    // FRB renames `extension` (Dart reserved word) to `extension_`.
    extension: b.extension_,
    filesize: b.filesize,
    filesizeString: b.filesizeString,
    interestScore: b.interestScore,
    readOnlineUrl: b.readOnlineUrl,
    volume: b.volume,
    isbn10: b.isbn10,
    isbn13: b.isbn13,
    ipfsCid: b.ipfsCid,
    ipfsCidBlake2b: b.ipfsCidBlake2B,
    ratingInterest: b.ratingInterest,
    ratingQuality: b.ratingQuality,
    readlistBookId: b.readlistBookId,
    note: b.note,
    // downloadedAt arrives as an ISO-8601 string from Rust; convert back to
    // DateTime with the same wall-clock values the server rendered.
    downloadedAt: _mapDownloadedAt(b.downloadedAt),
  );
}

DateTime? _mapDownloadedAt(String? iso) =>
    iso == null ? null : DateTime.tryParse(iso);
