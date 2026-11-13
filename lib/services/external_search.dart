// Excerpt ported from warreth/OpenlibExtended (AGPL-3.0) —
// lib/services/search_manager.dart (SearchProviderId, SearchProvider,
// SearchQuery, AnnasArchiveProvider, LibgenProvider, SearchManagerResult
// only). ZlibraryProvider, WelibProvider and SearchManager were NOT taken.
// zlibx is AGPL-3.0 (see LICENSE).
// Dart imports:
import 'dart:async';

// Flutter imports:
import 'package:flutter/foundation.dart';

// Package imports:
import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

// Project imports:
import 'package:zlibx/services/annas_archieve.dart';
import 'package:zlibx/services/external_logger.dart';
import 'package:zlibx/services/http_client.dart';
import 'package:zlibx/services/instance_manager.dart';
import 'package:zlibx/services/network_error.dart';

/// One searchable catalog the app can query.
enum SearchProviderId { annasArchive, libgen, zlibrary, welib }

/// A source of [BookData] results. Implementations own their fetching,
/// parsing and error handling - the manager merges whatever comes back.
abstract class SearchProvider {
  /// Stable id for persistence and settings toggles.
  SearchProviderId get id;

  /// Human name shown in settings.
  String get displayName;

  /// Runs a search. Must return [] when nothing matches; throws when the
  /// provider is unreachable. A throw is contained by the manager.
  Future<List<BookData>> search(SearchQuery query);
}

/// The filters the results page collects, in provider-neutral form.
///
/// [author], [publisher] and [year] carry field-specific values from
/// the advanced search panel; providers translate them into whatever
/// their backend supports.
@immutable
class SearchQuery {
  final String text;
  final String content;
  final String sort;
  final String fileType;
  final String language;
  final String year;
  final String author;
  final String publisher;
  final bool filtersEnabled;
  final int page;

  /// Null keeps the automatic fallback chain; a selection searches only that catalog.
  final SearchProviderId? source;

  const SearchQuery({
    required this.text,
    this.content = '',
    this.sort = '',
    this.fileType = '',
    this.language = '',
    this.year = '',
    this.author = '',
    this.publisher = '',
    this.filtersEnabled = false,
    this.page = 1,
    this.source,
  });

  bool get isEmpty =>
      text.trim().isEmpty && author.trim().isEmpty && publisher.trim().isEmpty;
}

/// Anna's Archive behind the provider interface: the existing
/// AnnasArchieve service with its challenge handling, unchanged.
class AnnasArchiveProvider implements SearchProvider {
  AnnasArchiveProvider({AnnasArchieve? api}) : _api = api ?? AnnasArchieve();

  final AnnasArchieve _api;

  @override
  SearchProviderId get id => SearchProviderId.annasArchive;

  @override
  String get displayName => "Anna's Archive";

  @override
  Future<List<BookData>> search(SearchQuery query) {
    return _api.searchBooks(
      searchQuery: query.text,
      content: query.content,
      sort: query.sort,
      fileType: query.fileType,
      language: query.language,
      year: query.year,
      author: query.author,
      publisher: query.publisher,
      enableFilters: query.filtersEnabled,
      page: query.page,
    );
  }
}

/// Browser headers shared by the external providers: the same
/// desktop-Chrome UA as every other app HTTP client (kDefaultUserAgent,
/// http_client.dart — one definition, W1).
const _browserHeaders = {'User-Agent': kDefaultUserAgent};

/// Library Genesis behind the provider interface — ported verbatim from
/// OpenlibExtended's search_manager.dart (LibgenProvider), except the
/// `.firstOrNull` call, which this codebase does not use (replaced by an
/// explicit empty check). No WebView needed: LibGen search pages are
/// plain HTML, and the detail page's `get.php` anchor is a direct
/// download URL (see libgen_service.dart).
class LibgenProvider implements SearchProvider {
  LibgenProvider({Dio? dio, List<String>? mirrors})
      : _dio = dio ??
            createDioWithLogging(
                options: BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              headers: _browserHeaders,
            )),
        _mirrors = mirrors;

  final Dio _dio;
  final List<String>? _mirrors;
  final AppLogger _logger = AppLogger();

  @override
  SearchProviderId get id => SearchProviderId.libgen;

  @override
  String get displayName => 'Library Genesis';

  /// Parses a libgen results page. Public so tests can feed a captured
  /// page without network. Handles both table layouts in the wild:
  /// the libgen.li/vg "tablelibgen" table and the older table.c.
  List<BookData> parseResults(String html, String baseUrl) {
    final document = html_parser.parse(html);

    // The libgen.li/vg family marks its results table with an id. The
    // older libgen layout uses a table.c; rows live in its tbody.
    final liRows = document.querySelectorAll('#tablelibgen tr');
    if (liRows.any((row) => row.querySelectorAll('td').length >= 9)) {
      return liRows
          .map((row) => _liRowToBook(row, baseUrl))
          .whereType<BookData>()
          .toList();
    }

    final legacyRows = document.querySelectorAll('table.c tbody tr');
    return legacyRows
        .map((row) => _legacyRowToBook(row, baseUrl))
        .whereType<BookData>()
        .toList();
  }

  BookData? _liRowToBook(dom.Element row, String baseUrl) {
    final cells = row.querySelectorAll('td');
    // libgen.li-family layout: [title(+links), author, series,
    // year, language, pages, size, extension, mirrors].
    if (cells.length < 9) return null;

    final titleCell = cells[0];
    // The first link points at series.php - the work's own title. The
    // edition links below it describe specific editions and DOI lines;
    // they are longer and would drown the real title out.
    final seriesLink =
        titleCell.querySelector('a[href*="series.php"], a[href*="index.php?"]');
    final title = (seriesLink ?? titleCell.querySelector('a'))?.text.trim() ??
        titleCell.text.trim();
    if (title.isEmpty) return null;

    // An md5 download link from the mirrors cell, if present. Fall
    // back to the edition link's id - unique per book either way.
    final md5Link = cells[8]
        .querySelectorAll('a[href*="md5="]')
        .map((a) => a.attributes['href'] ?? '')
        .whereType<String>()
        .toList();
    final idMatches = cells[0]
        .querySelectorAll('a[href*="id="]')
        .map((a) => RegExp(r'id=(\d+)')
            .firstMatch(a.attributes['href'] ?? '')
            ?.group(1))
        .whereType<String>()
        .toList();
    final md5 =
        _md5FromHref(md5Link) ?? (idMatches.isEmpty ? null : idMatches.first);

    String cell(int i) => cells.length > i ? cells[i].text.trim() : '';

    final info = [
      cell(4), // language
      if (cell(7).isNotEmpty) cell(7).toUpperCase(), // extension
      cell(6).replaceAll(RegExp(r'\s+'), ' '), // size
      cell(3), // year
    ].where((s) => s.isNotEmpty).join(', ');

    final md5Value = md5;
    final fallbackLink = titleCell.querySelector('a');
    final fallbackHref = fallbackLink?.attributes['href'] ?? '';
    return BookData(
      title: title,
      author: cell(1).isEmpty ? 'Unknown' : cell(1),
      thumbnail: null,
      link: md5Value != null
          ? '$baseUrl/ads.php?md5=$md5Value'
          : (fallbackHref.startsWith('http')
              ? fallbackHref
              : '$baseUrl$fallbackHref'),
      md5: md5Value ?? title,
      publisher: cell(2).isEmpty ? null : cell(2),
      info: info.isEmpty ? null : info,
    );
  }

  BookData? _legacyRowToBook(dom.Element row, String baseUrl) {
    final cells = row.querySelectorAll('td');
    // Older libgen layout: [id, author, title(+link), publisher, year,
    // pages, language, size, extension, ...mirror links].
    if (cells.length < 5) return null;

    final titleCell = cells[2];
    final titleLink = titleCell.querySelector('a');
    final href = titleLink?.attributes['href'];
    final title = (titleLink?.text ?? titleCell.text).trim();
    if (title.isEmpty || href == null) return null;

    String cell(int i) => cells.length > i ? cells[i].text.trim() : '';

    final info = [
      cell(6), // language
      if (cell(8).isNotEmpty) cell(8).toUpperCase(), // extension
      cell(7), // size
      cell(4), // year
    ].where((s) => s.isNotEmpty).join(', ');

    return BookData(
      title: title,
      author: cell(1).isEmpty ? 'Unknown' : cell(1),
      thumbnail: null,
      link: href.startsWith('http') ? href : '$baseUrl$href',
      md5: _md5FromHref([href]) ?? title,
      publisher: cell(3).isEmpty ? null : cell(3),
      info: info.isEmpty ? null : info,
    );
  }

  String? _md5FromHref(List<String> hrefs) {
    for (final href in hrefs) {
      final match = RegExp(r'[?&]md5=([0-9a-fA-F]{32})').firstMatch(href);
      if (match != null) return match.group(1);
    }
    return null;
  }

  @override
  Future<List<BookData>> search(SearchQuery query) async {
    // Field-specific search: libgen.li/vg accept columns[]= codes
    // restricting which fields 'req' is matched against - a=author,
    // p=publisher, t=title. When the user gave an author or publisher,
    // fold both into req and restrict matching to those columns so
    // 'Asimov' finds books BY Asimov, not books mentioning him.
    final author = query.author.trim();
    final publisher = query.publisher.trim();
    final useColumns =
        query.filtersEnabled && (author.isNotEmpty || publisher.isNotEmpty);
    final req = useColumns
        ? [
            if (author.isNotEmpty) author,
            if (publisher.isNotEmpty) publisher,
            if (query.text.trim().isNotEmpty) query.text.trim(),
          ].join(' ')
        : query.text;

    final params = StringBuffer('req=${Uri.encodeQueryComponent(req)}');
    if (useColumns) {
      if (author.isNotEmpty) params.write('&columns[]=a');
      if (publisher.isNotEmpty) params.write('&columns[]=p');
    }
    if (query.filtersEnabled) {
      if (query.fileType.isNotEmpty) {
        params.write('&extension=${Uri.encodeQueryComponent(query.fileType)}');
      }
      if (query.language.isNotEmpty) {
        params.write('&language=${Uri.encodeQueryComponent(query.language)}');
      }
      if (query.year.isNotEmpty) {
        params.write('&year=${Uri.encodeQueryComponent(query.year)}');
      }
    }
    if (query.page > 1) {
      params.write('&page=${query.page}');
    }

    final mirrors =
        _mirrors ?? await InstanceManager().enabledUrls(MirrorService.libgen);

    if (mirrors.isEmpty) {
      // Every libgen mirror SLUM knows is DOWN (or switched off by the
      // user). The contract is to never touch a down host, so this ends
      // here instead of throwing against a dead address.
      _logger.warning('No attemptable libgen mirror; not searching',
          tag: 'LibgenProvider');
      return const [];
    }

    _logger.info('Searching Library Genesis', tag: 'LibgenProvider', metadata: {
      'req': req,
      'page': query.page,
      'mirrors': mirrors.length,
    });

    Object? lastError;
    for (final mirror in mirrors) {
      try {
        final response = await _dio.get('$mirror/index.php?$params&res=100');
        if (response.statusCode != 200) {
          _logger.warning('Libgen mirror answered with a non-200',
              tag: 'LibgenProvider',
              metadata: {'mirror': mirror, 'status': response.statusCode});
          continue;
        }
        final html = response.data.toString();
        final books = parseResults(html, mirror);
        _logger.info('Libgen search returned ${books.length} books',
            tag: 'LibgenProvider', metadata: {'mirror': mirror});
        if (books.isNotEmpty) return books;
        // A challenge/error/placeholder page also parses to an empty
        // list. Only a real LibGen page may answer "no results"; on
        // anything else keep trying the remaining mirrors — otherwise
        // one protected mirror makes the search look empty forever
        // (same failure the Anna's Archive side fixed via
        // _isAnnasArchivePage).
        final looksLikeLibgenPage =
            html.contains('Library Genesis') || html.contains('libgen');
        if (looksLikeLibgenPage) {
          return books;
        }
        _logger.warning(
            'Libgen mirror returned a non-LibGen page (possible '
            'challenge page), trying next',
            tag: 'LibgenProvider',
            metadata: {'mirror': mirror, 'htmlLength': html.length});
      } catch (e) {
        lastError = e;
        _logger.warning('Libgen mirror failed, trying next',
            tag: 'LibgenProvider', error: e, metadata: {'mirror': mirror});
      }
    }
    _logger.error('All libgen mirrors failed',
        tag: 'LibgenProvider', error: lastError);
    // Short user-facing message only: the provider surfaces
    // NetworkError.userMessage, and the full Dio dump stays in the log
    // line above — it used to be shown verbatim in the search UI.
    throw NetworkError(
      type: NetworkErrorType.serverUnavailable,
      userMessage: 'Library Genesis temporarily unavailable',
      solution: 'The LibGen mirrors are not answering right now. '
          'Please try again in a moment.',
      technicalDetails: lastError.toString(),
    );
  }
}

/// Combined outcome of a fan-out search.
@immutable
class SearchManagerResult {
  final List<BookData> books;

  /// Display names of providers that threw; the UI can mention them while
  /// still showing the surviving results.
  final List<String> failedProviders;

  /// The catalog the returned books came from ('' when several sources
  /// contributed or none found anything). Single value because the chain
  /// stops at the first provider with results.
  final String resultSource;

  const SearchManagerResult(
      {required this.books,
      required this.failedProviders,
      this.resultSource = ''});
}
