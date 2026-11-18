import 'package:flutter/foundation.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart' as zl;
import '../lib.dart' as frb_api;
import '../models.dart' as frb;
import 'rust_init.dart';

/// Phase 3: wires the Rust-backed booklist / category / download-stats
/// parsers into the vendor plugin's parse hooks. Same architecture as
/// rust_fulltext.dart / rust_article.dart / rust_book_detail.dart:
/// lazy FRB init (never blocks startup, silently falls back to Dart),
/// and a model mapping layer to the hand-written vendor models.
///
/// Call [injectRustBooklistParsers] once from `main()`.
void injectRustBooklistParsers() {
  zl.booklistsPageParseOverride = _rustBooklistsPage;
  zl.userProfileBooklistsParseOverride = _rustUserProfileBooklists;
  zl.booklistDetailBooksParseOverride = _rustBooklistDetailBooks;
  zl.categoryPageParseOverride = _rustCategoryPage;
  zl.downloadStatsParseOverride = _rustDownloadStats;
}

/// Shared one-shot FRB init (same engine as the other hooks; the
/// duplicate guard keeps each hook independent and testable).
Future<void> _ensureInit() async {
  await ensureRustBridge();
}

/// Un-register every hook after a bridge failure, so all list-family
/// parsers fall back to Dart together (one init failure is enough
/// evidence the bridge is unavailable on this host).
void _unregisterAll() {
  if (kDebugMode) {
    debugPrint('[FRB] list-family bridge init failed, falling back to Dart');
  }
  resetRustBridge();
  zl.booklistsPageParseOverride = null;
  zl.userProfileBooklistsParseOverride = null;
  zl.booklistDetailBooksParseOverride = null;
  zl.categoryPageParseOverride = null;
  zl.downloadStatsParseOverride = null;
}

// ──────────────────────────────────────────────────────────────────
// Hook bodies
// ──────────────────────────────────────────────────────────────────

Future<zl.BooklistsPage> _rustBooklistsPage(String html, String baseUrl) async {
  try {
    await _ensureInit();
  } on Object {
    _unregisterAll();
    return zl.parseBooklistsPage(html, baseUrl: baseUrl);
  }
  final page = await frb_api.parseBooklistsPage(html: html, baseUrl: baseUrl);
  if (kDebugMode) {
    debugPrint(
      '[FRB] booklists parsed via Rust: ${page.lists.length} lists, '
      'pages ${page.totalPages}',
    );
  }
  return _mapBooklistsPage(page);
}

Future<List<zl.Booklist>> _rustUserProfileBooklists(
  String html,
  String baseUrl,
) async {
  try {
    await _ensureInit();
  } on Object {
    _unregisterAll();
    return zl.parseUserProfileBooklists(html, baseUrl: baseUrl);
  }
  final lists = await frb_api.parseUserProfileBooklists(
    html: html,
    baseUrl: baseUrl,
  );
  if (kDebugMode) {
    debugPrint('[FRB] profile booklists parsed via Rust: ${lists.length}');
  }
  return lists.map(_mapBooklist).toList();
}

Future<List<zl.Book>> _rustBooklistDetailBooks(
  String html,
  String? baseUrl,
) async {
  try {
    await _ensureInit();
  } on Object {
    _unregisterAll();
    return zl.parseBooklistDetailBooks(html, baseUrl: baseUrl);
  }
  final books = await frb_api.parseBooklistDetailBooks(
    html: html,
    baseUrl: baseUrl ?? '',
  );
  if (kDebugMode) {
    debugPrint('[FRB] booklist detail parsed via Rust: ${books.length} books');
  }
  return books.map((b) => _mapBook(b)).toList();
}

Future<zl.CategoryPage> _rustCategoryPage(String html, String? baseUrl) async {
  try {
    await _ensureInit();
  } on Object {
    _unregisterAll();
    return zl.parseCategoryBooksPage(html, baseUrl: baseUrl);
  }
  final page = await frb_api.parseCategoryBooksPage(
    html: html,
    baseUrl: baseUrl ?? '',
  );
  if (kDebugMode) {
    debugPrint(
      '[FRB] category parsed via Rust: ${page.books.length} books, '
      'slug ${page.searchSlug != null}',
    );
  }
  return _mapCategoryPage(page);
}

Future<List<zl.Book>> _rustDownloadStats(String html) async {
  try {
    await _ensureInit();
  } on Object {
    _unregisterAll();
    return zl.parseDownloadStatsPage(html);
  }
  final books = await frb_api.parseDownloadStatsPage(html: html);
  if (kDebugMode) {
    debugPrint('[FRB] dstats parsed via Rust: ${books.length} rows');
  }
  return books.map(_mapDstatsBook).toList();
}

// ──────────────────────────────────────────────────────────────────
// Model mapping (FRB structs → hand-written vendor models)
// ──────────────────────────────────────────────────────────────────

zl.BooklistsPage _mapBooklistsPage(frb.BooklistsPage page) {
  return zl.BooklistsPage(
    lists: page.lists.map(_mapBooklist).toList(),
    totalPages: page.totalPages,
  );
}

zl.Booklist _mapBooklist(frb.Booklist l) {
  return zl.Booklist(
    id: l.id,
    name: l.name,
    description: l.description,
    author: l.author,
    authorProfile: l.authorProfile,
    authorAvatar: l.authorAvatar,
    count: l.count,
    views: l.views,
    comments: l.comments,
    color: l.color,
    isPrivate: l.isPrivate,
    isFavorite: l.isFavorite,
    coverUrl: l.coverUrl,
    url: l.url,
    previewBooks: l.previewBooks.map(_mapBook).toList(),
  );
}

zl.CategoryPage _mapCategoryPage(frb.CategoryPage page) {
  return zl.CategoryPage(
    books: page.books
        .map(
          (c) => zl.CategoryBook(
            book: _mapBook(c.book),
            isFavorite: c.isFavorite,
            unavailableReason: c.unavailableReason,
          ),
        )
        .toList(),
    totalPages: page.totalPages,
    searchSlug: page.searchSlug,
  );
}

/// Full-field Book mapping, shared by the booklist/category parsers.
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
    downloadedAt: _mapDownloadedAt(b.downloadedAt),
  );
}

/// dstats rows carry the stamp as an ISO-8601 local string
/// (`2026-11-11T21:02:00`); convert back to DateTime with the same
/// wall-clock values the site rendered.
DateTime? _mapDownloadedAt(String? iso) =>
    iso == null ? null : DateTime.tryParse(iso);

/// dstats rows only populate id/title/hash/href/downloadedAt — no
/// other field ever leaks a value.
zl.Book _mapDstatsBook(frb.Book b) => _mapBook(b);
