import 'package:flutter/foundation.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart' as zl;
import '../lib.dart' as frb_api;
import '../models.dart' as frb;
import 'rust_init.dart';

/// Phase 2 pilot: wires the Rust-backed full-text parser into the
/// vendor plugin's `fulltextParseOverride` hook.
///
/// - FRB runs `parse_fulltext_search_page` on the Rust thread pool,
///   replacing the Dart `Isolate.run` path for the heavy parse work.
/// - The bridge initializes lazily on the FIRST full-text search, so
///   app startup is never blocked (and a missing `.so` — e.g. running
///   on a non-Android host — can never stall launch).
/// - On any bridge failure the hook un-registers itself and the parse
///   falls back to the Dart implementation: behavior identical either
///   way (test/parsers/fulltext_test.dart is the contract for both).
///
/// Call [injectRustFulltextParser] once from `main()`.
void injectRustFulltextParser() {
  zl.fulltextParseOverride = _rustParseFulltext;
}

Future<zl.FullTextSearchPage> _rustParseFulltext(
  String html,
  String? baseUrl,
) async {
  try {
    await ensureRustBridge();
  } on Object catch (e) {
    // Bridge unavailable (lib loading failed, wrong platform, ...):
    // un-register and let the vendor's Dart parser take over.
    if (kDebugMode) {
      debugPrint('[FRB] bridge init failed, falling back to Dart: $e');
    }
    resetRustBridge();
    zl.fulltextParseOverride = null;
    return zl.parseFullTextSearchPage(html, baseUrl: baseUrl);
  }
  // FRB wraps Option<String> params as plain String; empty = no base URL.
  final page = await frb_api.parseFulltextSearchPage(
    html: html,
    baseUrl: baseUrl ?? '',
  );
  if (kDebugMode) {
    debugPrint(
      '[FRB] fulltext parsed via Rust: ${page.hits.length} hits, '
      'total ${page.total}, pages ${page.totalPages}',
    );
  }
  return _mapFullTextPage(page);
}

// ──────────────────────────────────────────────────────────────────
// FRB-generated models → hand-written vendor models.
// Field-name deltas: extension_ (Dart reserved word in FRB output),
// ipfsCidBlake2B vs vendor ipfsCidBlake2b (case).
// ──────────────────────────────────────────────────────────────────

zl.FullTextSearchPage _mapFullTextPage(frb.FullTextSearchPage page) {
  return zl.FullTextSearchPage(
    hits: page.hits.map(_mapHit).toList(),
    total: page.total,
    totalPages: page.totalPages,
  );
}

zl.FullTextHit _mapHit(frb.FullTextHit hit) {
  return zl.FullTextHit(
    book: _mapBook(hit.book),
    snippet: hit.snippet
        .map(
          (part) => zl.FullTextSnippetPart(
            text: part.text,
            highlighted: part.highlighted,
          ),
        )
        .toList(),
    removed: hit.removed,
    unavailableReason: hit.unavailableReason,
  );
}

zl.Book _mapBook(frb.Book book) {
  return zl.Book(
    id: book.id,
    title: book.title,
    hash: book.hash,
    href: book.href,
    author: book.author,
    cover: book.cover,
    description: book.description,
    publisher: book.publisher,
    year: book.year,
    language: book.language,
    categories: book.categories,
    pages: book.pages,
    series: book.series,
    // FRB renames `extension` (Dart reserved word) to `extension_`.
    extension: book.extension_,
    filesize: book.filesize,
    filesizeString: book.filesizeString,
    interestScore: book.interestScore,
    readOnlineUrl: book.readOnlineUrl,
    // Fields below are never populated by the fulltext parser; the
    // vendor Book defaults them to null. Map them anyway so a future
    // parser sharing this Book mapper stays correct.
    volume: book.volume,
    isbn10: book.isbn10,
    isbn13: book.isbn13,
    ipfsCid: book.ipfsCid,
    ipfsCidBlake2b: book.ipfsCidBlake2B,
    ratingInterest: book.ratingInterest,
    ratingQuality: book.ratingQuality,
    readlistBookId: book.readlistBookId,
    note: book.note,
    // downloadedAt: FRB carries it as ISO-8601 String; the fulltext
    // parser never sets it, so leave it null rather than parsing.
  );
}
