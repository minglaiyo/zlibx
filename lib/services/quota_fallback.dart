// Quota-exhausted fallback: when the user's Z-Library account has no
// downloads left today, look the same book up on LibGen / Anna's Archive
// and hand back a resolved download URL so the download can continue
// from the other source instead of just showing the quota dialog.
//
// Order: LibGen first (plain-HTML search, get.php is a direct link, no
// donation key and no WebView challenge in the way), then Anna's Archive
// (bigger catalog, but the download needs the donation key for the fast
// route, otherwise the slow WebView route).
//
// Matching is fuzzy (title/author/format): the best-scored result wins,
// and a title search requires a real title match. An ISBN search is
// exact by construction, so any result is accepted (best-scored first).
// A source that finds nothing (or whose detail/link resolution fails)
// falls through to the next; when neither has the book, the caller
// shows the quota dialog as before.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../core/annas_archive.dart';
import '../models/display_book.dart';
import '../utils/app_log.dart';
import '../utils/diagnostics.dart';
import 'annas_archieve.dart';
import 'external_download.dart';
import 'external_search.dart';
import 'libgen_service.dart';

/// A book found on another source, ready to download.
class QuotaFallbackResult {
  const QuotaFallbackResult({
    required this.book,
    required this.url,
    required this.source,
  });

  /// Synthesized external Book, re-keyed to the z站 book's id: the
  /// detail page looks up download progress/completion by the z站
  /// book id, so an external-md5 id would leave the task invisible
  /// there (no progress bar, and the button never flips to 打开).
  /// The external md5 stays in `hash` (integrity check) and the
  /// format stays the external file's.
  final Book book;

  /// Resolved direct download URL for [book].
  final String url;

  /// Which source the book came from.
  final BookSource source;
}

/// Minimum match score for a title search to be accepted: the title
/// must match exactly (100), or partially with an exact author (60+40).
const _minTitleSearchScore = 100;

/// Whole-fallback budget: the Anna slow-link WebView route can take a
/// while, but the user must eventually see the quota dialog instead of
/// waiting forever. The in-flight attempt keeps running in the
/// background and is discarded when it finishes.
const _fallbackTimeout = Duration(seconds: 120);

/// Looks the z站 book up on LibGen, then Anna's Archive, and resolves a
/// download URL for the best match. Returns null when neither source
/// has the book (or every route failed). Never throws.
Future<QuotaFallbackResult?> tryQuotaFallback({
  required Book zBook,
  required AnnasArchieve annasApi,
  required LibgenService libgenService,
  required LibgenProvider libgenSearch,
}) async {
  // Prefer the ISBN: an exact identifier beats a fuzzy title match.
  final isbn = _isbnOf(zBook);
  final title = zBook.title.trim();
  final query = isbn ?? title;
  if (query.isEmpty) return null;
  final isIsbnQuery = isbn != null;

  QuotaFallbackResult? result;
  try {
    result = await _tryFallback(
      zBook: zBook,
      query: query,
      isIsbnQuery: isIsbnQuery,
      annasApi: annasApi,
      libgenService: libgenService,
      libgenSearch: libgenSearch,
    ).timeout(_fallbackTimeout, onTimeout: () => null);
  } on Object catch (error) {
    logIgnored('quota_fallback', error);
    result = null;
  }
  AppLog.report(
    'quota fallback: ${result == null ? 'not found' : 'found on ${result.source.name}'}',
    tag: 'quota_fallback',
  );
  return result;
}

Future<QuotaFallbackResult?> _tryFallback({
  required Book zBook,
  required String query,
  required bool isIsbnQuery,
  required AnnasArchieve annasApi,
  required LibgenService libgenService,
  required LibgenProvider libgenSearch,
}) async {
  // LibGen first: plain-HTML search and a direct get.php link.
  final libgen = await _trySource(
    zBook: zBook,
    isIsbnQuery: isIsbnQuery,
    source: BookSource.libgen,
    search: () => libgenSearch.search(SearchQuery(text: query)),
    detail: (link) => libgenService.bookInfo(link),
  );
  if (libgen != null) return libgen;

  // Then Anna's Archive: bigger catalog, slower download routes.
  return _trySource(
    zBook: zBook,
    isIsbnQuery: isIsbnQuery,
    source: BookSource.annasArchive,
    search: () => annasApi.searchBooks(searchQuery: query),
    detail: (link) => annasApi.bookInfo(url: link),
  );
}

/// One source's search → best match → detail → download-URL chain.
/// Any step failing (or finding nothing) ends this source, and the
/// caller falls through to the next one.
Future<QuotaFallbackResult?> _trySource({
  required Book zBook,
  required bool isIsbnQuery,
  required BookSource source,
  required Future<List<BookData>> Function() search,
  required Future<BookInfoData?> Function(String link) detail,
}) async {
  List<BookData> results;
  try {
    results = await search();
  } on Object catch (error) {
    logIgnored('quota_fallback_search', error);
    return null;
  }
  if (results.isEmpty) return null;
  final best = _bestMatch(results, zBook);
  if (best == null) return null;
  // A title search must actually match the title; an ISBN search is
  // exact by construction, so any result is accepted.
  if (!isIsbnQuery &&
      quotaFallbackMatchScore(
            best,
            title: zBook.title,
            author: zBook.author,
            extension: zBook.extension,
          ) <
          _minTitleSearchScore) {
    return null;
  }
  BookInfoData? info;
  try {
    info = await detail(best.link);
  } on Object catch (error) {
    logIgnored('quota_fallback_detail', error);
    return null;
  }
  if (info == null) return null;
  final target = await resolveExternalDownload(info);
  if (!target.hasUrl) return null;
  return QuotaFallbackResult(
    // Re-key the task to the z站 book's id: the detail page's
    // progress/completion lookup keys on it, so the external-md5 id
    // would leave the download invisible there — no progress bar,
    // and the button never flips to 打开. The external md5 stays in
    // `hash` (integrity check) and the format stays the external
    // file's.
    book: synthesizeExternalBook(info).copyWith(id: zBook.id),
    url: target.url!,
    source: source,
  );
}

/// Highest-scored result, or null when the list is empty.
BookData? _bestMatch(List<BookData> results, Book zBook) {
  BookData? best;
  var bestScore = -1;
  for (final candidate in results) {
    final score = quotaFallbackMatchScore(
      candidate,
      title: zBook.title,
      author: zBook.author,
      extension: zBook.extension,
    );
    if (score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }
  return best;
}

/// Best-match score for one external result against the z站 book:
/// title exact 100, title contains 60, author exact 40, author
/// contains 20, same format 10.
@visibleForTesting
int quotaFallbackMatchScore(
  BookData candidate, {
  required String title,
  String? author,
  String? extension,
}) {
  var score = 0;
  final candidateTitle = _normalize(candidate.title);
  final wantedTitle = _normalize(title);
  if (candidateTitle.isNotEmpty && wantedTitle.isNotEmpty) {
    if (candidateTitle == wantedTitle) {
      score += 100;
    } else if (candidateTitle.contains(wantedTitle) ||
        wantedTitle.contains(candidateTitle)) {
      score += 60;
    }
  }
  final candidateAuthor = _normalize(candidate.author ?? '');
  final wantedAuthor = _normalize(author ?? '');
  if (candidateAuthor.isNotEmpty && wantedAuthor.isNotEmpty) {
    if (candidateAuthor == wantedAuthor) {
      score += 40;
    } else if (candidateAuthor.contains(wantedAuthor) ||
        wantedAuthor.contains(candidateAuthor)) {
      score += 20;
    }
  }
  final wantedExt = (extension ?? '').trim().toLowerCase();
  if (wantedExt.isNotEmpty) {
    final format = ArchiveParsing.formatFromInfo(candidate.info).toLowerCase();
    if (format == wantedExt) score += 10;
  }
  return score;
}

/// Lowercase, drop punctuation/whitespace: "Dune: Part One" and
/// "Dune Part One" normalize to the same string.
String _normalize(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');
}

/// The book's ISBN-13 (preferred) or ISBN-10, hyphens/spaces stripped.
String? _isbnOf(Book book) {
  final isbn13 = book.isbn13?.replaceAll(RegExp(r'[-\s]'), '');
  if (isbn13 != null && isbn13.isNotEmpty) return isbn13;
  final isbn10 = book.isbn10?.replaceAll(RegExp(r'[-\s]'), '');
  if (isbn10 != null && isbn10.isNotEmpty) return isbn10;
  return null;
}
