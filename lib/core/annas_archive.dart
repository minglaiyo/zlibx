// Ported from warreth/OpenlibExtended (AGPL-3.0) — Anna's Archive / LibGen
// book sources. Original file: lib/core/annas_archive.dart
// zlibx is AGPL-3.0 (see LICENSE); upstream MIT attribution for
// shiyi-0x7f/olib-mobile is preserved in LICENSE.
// Pure-Dart Anna's Archive parsing shared by the Flutter app and the CLI.
//
// Nothing in this file may import Flutter: the helpers are pure Dart
// (the old `bin/ai_cli.dart` CLI is gone — there is no `bin/` in the
// repo), and the app services import them too.

// Package imports:
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' show parse;

/// One search result or detail record from Anna's Archive.
class ArchiveBook {
  final String title;
  final String? author;
  final String? thumbnail;
  final String link;
  final String md5;
  final String? publisher;
  final String? info;

  const ArchiveBook({
    required this.title,
    this.author,
    this.thumbnail,
    required this.link,
    required this.md5,
    this.publisher,
    this.info,
  });

  /// Best-effort format guess from the metadata line.
  String get format => ArchiveParsing.formatFromInfo(info);
}

/// A parsed `/md5/<md5>` detail page.
class ArchiveBookDetails extends ArchiveBook {
  /// The book description, when the page has one.
  final String? description;

  /// The `/slow_download/<...>` link on the detail page, when present.
  final String? slowDownloadUrl;

  const ArchiveBookDetails({
    required super.title,
    super.author,
    super.thumbnail,
    required super.link,
    required super.md5,
    super.publisher,
    super.info,
    this.description,
    this.slowDownloadUrl,
  });
}

/// Stateless Anna's Archive parsing and URL building.
///
/// The app and the CLI both call these functions so a selector fix or a URL
/// change only has to be made once.
class ArchiveParsing {
  // Compiled once: cleanText runs for every title/author/publisher of
  // every search-result row — re-building six RegExp instances per call
  // was pure overhead on the hottest parsing path.
  static final RegExp _reEmojiBlock = RegExp(
    r'[\u{1F300}-\u{1F9FF}]',
    unicode: true,
  );
  static final RegExp _reMiscSymbols = RegExp(
    r'[\u{2600}-\u{26FF}]',
    unicode: true,
  );
  static final RegExp _reDingbats = RegExp(
    r'[\u{2700}-\u{27BF}]',
    unicode: true,
  );
  static final RegExp _reEmoticons = RegExp(
    r'[\u{1F600}-\u{1F64F}]',
    unicode: true,
  );
  static final RegExp _reTransport = RegExp(
    r'[\u{1F680}-\u{1F6FF}]',
    unicode: true,
  );
  static final RegExp _reWhitespace = RegExp(r'\s+');

  /// Removes emoji/icon noise and collapses whitespace.
  static String cleanText(String text) {
    return text
        .replaceAll(_reEmojiBlock, '')
        .replaceAll(_reMiscSymbols, '')
        .replaceAll(_reDingbats, '')
        .replaceAll(_reEmoticons, '')
        .replaceAll(_reTransport, '')
        .replaceAll('🔍', '')
        .replaceAll(_reWhitespace, ' ')
        .trim();
  }

  /// Formats Anna's Archive commonly puts in its info line, checked with
  /// word boundaries so a title mentioning "pdf" cannot win over the
  /// real format token. Unknown formats fall back to `epub` (unchanged
  /// from the previous behavior for unrecognized entries).
  static const List<String> _knownFormats = [
    'pdf',
    'epub',
    'mobi',
    'azw3',
    'fb2',
    'djvu',
    'cbz',
    'cbr',
    'txt',
    'rtf',
    'doc',
    'docx',
    'lit',
    'chm',
  ];

  /// Detects the book format from the info line, defaulting to `epub`.
  static final List<MapEntry<String, RegExp>> _knownFormatMatchers = [
    for (final format in _knownFormats)
      MapEntry(format, RegExp(r'\b' + format + r'\b')),
  ];

  static String formatFromInfo(String? info) {
    final lower = (info ?? '').toLowerCase();
    for (final entry in _knownFormatMatchers) {
      if (entry.value.hasMatch(lower)) return entry.key;
    }
    return 'epub';
  }

  /// Returns the md5 segment from a path or URL.
  static String md5FromLink(String urlOrPath) {
    final uri = Uri.parse(urlOrPath);
    final segments = uri.pathSegments;
    final md5Index = segments.indexOf('md5');
    if (md5Index >= 0 && md5Index + 1 < segments.length) {
      return segments[md5Index + 1];
    }
    return segments.isNotEmpty ? segments.last : '';
  }

  /// Text as a browser renders it: script/style contents are removed.
  ///
  /// Anna's Archive embeds click handlers as inline `<script>` tags inside
  /// metadata boxes, and `package:html`'s `.text` includes their source.
  static String visibleText(dom.Element? element) {
    if (element == null) return '';
    final clone = element.clone(true);
    for (final node in clone.querySelectorAll('script, style')) {
      node.remove();
    }
    return clone.text.trim();
  }

  static String resolveUrl(String baseUrl, String href) {
    if (href.startsWith('http://') || href.startsWith('https://')) {
      return href;
    }
    final base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/');
    return base.resolve(href).toString();
  }

  static String resolveRelative(String href, String pageUrl) {
    if (href.startsWith('http://') || href.startsWith('https://')) {
      return href;
    }
    return Uri.parse(pageUrl).resolve(href).toString();
  }

  /// Builds a `/search` URL. Mirrors the app's historical `urlEncoder`:
  /// author/publisher become field-scoped terms inside `q`, filters ride the
  /// documented query parameters, and page 1 omits `page`.
  ///
  /// [enableFilters] lets callers force the plain URL (the app disables the
  /// filter UI on trending/category pages). When omitted, filters are used
  /// whenever any filter value is present.
  static String buildSearchUrl({
    required String baseUrl,
    required String query,
    String content = '',
    String sort = '',
    String fileType = '',
    String language = '',
    String year = '',
    String? yearFrom,
    String? yearTo,
    String author = '',
    String publisher = '',
    bool? enableFilters,
    int page = 1,
  }) {
    final fieldTerms = StringBuffer();
    if (author.trim().isNotEmpty) {
      fieldTerms.write(
        'author:%22${Uri.encodeQueryComponent(author.trim())}%22 ',
      );
    }
    if (publisher.trim().isNotEmpty) {
      fieldTerms.write(
        'publisher:%22${Uri.encodeQueryComponent(publisher.trim())}%22 ',
      );
    }
    final encodedQuery =
        '${fieldTerms.toString()}${Uri.encodeQueryComponent(query.trim())}';

    final hasYearRange =
        (yearFrom?.isNotEmpty ?? false) || (yearTo?.isNotEmpty ?? false);
    final filters =
        enableFilters ??
        (content.isNotEmpty ||
            sort.isNotEmpty ||
            fileType.isNotEmpty ||
            language.isNotEmpty ||
            year.isNotEmpty ||
            hasYearRange);

    final pageParam = page > 1 ? '&page=$page' : '';
    if (!filters) {
      return '$baseUrl/search?q=$encodedQuery$pageParam';
    }

    var url = '$baseUrl/search?index=&sort=$sort';
    if (language.isNotEmpty) url += '&lang=$language';
    url += '&display=';
    url += '&q=$encodedQuery';
    if (content.isNotEmpty) url += '&content=$content';
    if (fileType.isNotEmpty) url += '&ext=$fileType';
    if (year.isNotEmpty) {
      if (year == 'Before 1980') {
        url += '&year_end=1979';
      } else if (year.contains('-')) {
        final parts = year.split('-');
        if (parts.length == 2) {
          url += '&year_from=${parts[0].trim()}&year_end=${parts[1].trim()}';
        }
      } else {
        url += '&year=$year';
      }
    }
    if (yearFrom != null && yearFrom.isNotEmpty) {
      url += '&year_from=${yearFrom.trim()}';
    }
    if (yearTo != null && yearTo.isNotEmpty) {
      url += '&year_end=${yearTo.trim()}';
    }
    return '$url$pageParam';
  }

  /// Parses a search results page, including the `/md5/` link fallback used
  /// when Anna's Archive changes the container markup.
  static List<ArchiveBook> parseSearchResults(
    String html, {
    required String baseUrl,
    String fileType = '',
  }) {
    final document = parse(html);
    var containers = document.querySelectorAll('div.flex.pt-3.pb-3.border-b');

    if (containers.isEmpty) {
      final md5Links = document.querySelectorAll('a[href*="/md5/"]');
      if (md5Links.isNotEmpty) {
        // Several links in one container (cover + title both pointing at
        // /md5/) used to add the SAME container twice — the book showed
        // up duplicated in the fallback results. A Set deduplicates by
        // element identity.
        final seenContainers = <dom.Element>{};
        for (final link in md5Links) {
          var parent = link.parent;
          while (parent != null && parent.localName != 'div') {
            parent = parent.parent;
          }
          if (parent != null) seenContainers.add(parent);
        }
        containers = seenContainers.toList();
      }
    }

    final books = <ArchiveBook>[];
    for (final container in containers) {
      final mainLink = container.querySelector(
        'a.line-clamp-\\[3\\].js-vim-focus',
      );
      final md5Link = container.querySelector('a[href*="/md5/"]');
      final linkElement = mainLink ?? md5Link;
      final thumbnailElement = container.querySelector('a[href*="/md5/"] img');

      final href = linkElement?.attributes['href'];
      if (href == null) continue;

      final title = cleanText(linkElement!.text.trim());
      final md5 = md5FromLink(href);
      final thumbnail = thumbnailElement?.attributes['src'];

      // Author and publisher are the two `/search?q=` links after the title
      // link, in document order.
      dom.Element? authorElement = linkElement.nextElementSibling;
      dom.Element? publisherElement = authorElement?.nextElementSibling;
      if (authorElement?.attributes['href']?.startsWith('/search?q=') != true) {
        authorElement = null;
      }
      if (publisherElement?.attributes['href']?.startsWith('/search?q=') !=
          true) {
        publisherElement = null;
      }

      final authorRaw = authorElement?.text.trim();
      final author = authorRaw == null
          ? null
          : (authorRaw.contains('icon-')
                ? cleanText(authorRaw.split(' ').skip(1).join(' ').trim())
                : cleanText(authorRaw));
      final publisherRaw = publisherElement?.text.trim();
      final publisher = publisherRaw != null ? cleanText(publisherRaw) : null;

      final info = visibleText(container.querySelector('div.text-gray-800'));

      final matchesType =
          fileType.isEmpty ||
          info.toLowerCase().contains(fileType.toLowerCase());
      if (!matchesType) continue;

      books.add(
        ArchiveBook(
          title: title,
          author: author?.isEmpty == true ? 'unknown' : author,
          thumbnail: thumbnail,
          link: resolveUrl(baseUrl, href),
          md5: md5,
          publisher: publisher?.isEmpty == true ? 'unknown' : publisher,
          info: info,
        ),
      );
    }
    return books;
  }

  /// Parses one `/md5/` detail page. Returns null when the page has no book
  /// record, which lets callers distinguish "not found" from a network error.
  static ArchiveBookDetails? parseBookDetails(
    String html, {
    required String url,
    required String baseUrl,
  }) {
    final document = parse(html);
    final main = document.querySelector('div.main-inner');
    if (main == null) return null;

    final titleElement = main.querySelector('div.font-semibold.text-2xl');
    if (titleElement == null) return null;

    String? slowDownload;
    final slowLinks = main.querySelectorAll(
      'ul.list-inside a[href*="/slow_download/"]',
    );
    final slowHref = slowLinks.isEmpty
        ? null
        : slowLinks.first.attributes['href'];
    if (slowHref != null && slowHref.isNotEmpty) {
      slowDownload = resolveUrl(baseUrl, slowHref);
    }

    final authorElement = main.querySelector('a[href^="/search?q="].text-base');
    dom.Element? publisherElement = authorElement?.nextElementSibling;
    if (publisherElement?.localName != 'a' ||
        publisherElement?.attributes['href']?.startsWith('/search?q=') !=
            true) {
      publisherElement = null;
    }

    final thumbnailElement = main.querySelector('div[id^="list_cover_"] img');

    dom.Element? descriptionElement;
    final descriptionLabel = main.querySelector(
      'div.js-md5-top-box-description div.text-xs.text-gray-500.uppercase',
    );
    if (descriptionLabel?.text.trim().toLowerCase() == 'description') {
      descriptionElement = descriptionLabel?.nextElementSibling;
    }

    final title = cleanText(titleElement.text.trim());
    final author = cleanText(authorElement?.text.trim() ?? 'unknown');
    final publisher = cleanText(publisherElement?.text.trim() ?? 'unknown');
    final info = visibleText(main.querySelector('div.text-gray-800'));

    return ArchiveBookDetails(
      title: title,
      author: author,
      thumbnail: thumbnailElement?.attributes['src'],
      publisher: publisher,
      info: info,
      link: url,
      md5: md5FromLink(url),
      description: visibleText(descriptionElement),
      slowDownloadUrl: slowDownload,
    );
  }

  /// True when a response is a bot-protection interstitial rather than the
  /// page that was requested.
  static bool isChallengeResponse({
    required int statusCode,
    required String body,
    String? cfMitigated,
  }) {
    if (cfMitigated?.toLowerCase() == 'challenge') return true;

    // L5: challenge markers all live in the document head — lowercase
    // only the first 64 KB instead of the whole body. A 2 MB page used
    // to allocate a lowercase copy per response, and a request may run
    // this check 2–3 times.
    final head = body.length > 65536 ? body.substring(0, 65536) : body;
    final lower = head.toLowerCase();
    if (lower.isEmpty) return false;

    final title =
        RegExp(
          r'<title[^>]*>([^<]*)</title>',
        ).firstMatch(lower)?.group(1)?.trim() ??
        '';
    const challengeTitles = [
      'just a moment',
      'ddos-guard',
      'checking your browser',
      'attention required',
    ];
    if (challengeTitles.any(title.startsWith)) return true;

    const hardMarkers = [
      'cf-browser-verification',
      'cf-challenge-running',
      '/cdn-cgi/challenge-platform/',
      'check.ddos-guard.net',
      'data-ddg-origin',
      '__ddg',
    ];
    if (hardMarkers.any(lower.contains)) return true;

    if (statusCode == 403 || statusCode == 503) {
      const softMarkers = [
        'checking your browser',
        'enable javascript and cookies',
        'needs to review the security of your connection',
        'verifying you are human',
        'browser check',
        'security check',
      ];
      if (softMarkers.any(lower.contains)) return true;
    }
    return false;
  }

  /// True when [html] is an Anna's Archive page rather than an unrelated
  /// site that happens to share the mirror host.
  static bool isArchivePage(String html) {
    final title =
        RegExp(
          r'<title[^>]*>([^<]*)</title>',
          caseSensitive: false,
        ).firstMatch(html)?.group(1)?.toLowerCase() ??
        '';
    return title.contains('anna') && title.contains('archive');
  }

  /// Extracts the direct download link from a `slow_download` page.
  static String? extractSlowDownloadLink(String html, {String pageUrl = ''}) {
    // L6: the slow-download page is parsed only for one link — a full
    // Dart DOM parse per call is wasteful. Locate the target paragraph
    // with a regex first (and parse nothing else); the full-page DOM
    // parse stays as the fallback for markup that does not match the
    // expected shape, so a site change degrades instead of losing
    // the link.
    final href = _slowLinkHrefByRegex(html) ?? _slowLinkHrefByDom(html);
    if (href == null || href.isEmpty) return null;
    if (pageUrl.isEmpty) return href;
    return resolveRelative(href, pageUrl);
  }

  /// Regex-first locate: the <p> whose class list contains mb-4,
  /// text-xl and font-bold (any order), then the first <a href> inside
  /// it. Double-quoted attributes only — anything else falls through
  /// to the DOM parse below.
  static String? _slowLinkHrefByRegex(String html) {
    final pOpen = RegExp(
      r'<p\b[^>]*\bclass\s*=\s*"([^"]*)"[^>]*>',
      caseSensitive: false,
    );
    for (final m in pOpen.allMatches(html)) {
      final classes = m.group(1)!.split(RegExp(r'\s+')).toSet();
      if (!classes.contains('mb-4') ||
          !classes.contains('text-xl') ||
          !classes.contains('font-bold')) {
        continue;
      }
      final after = html.substring(m.end);
      final end = after.indexOf('</p>');
      final inner = end >= 0 ? after.substring(0, end) : after;
      final href = RegExp(
        r'<a\b[^>]*\bhref\s*=\s*"([^"]+)"',
        caseSensitive: false,
      ).firstMatch(inner)?.group(1);
      if (href != null && href.isNotEmpty) return href;
    }
    return null;
  }

  /// The original full-page DOM parse, kept as the fallback.
  /// Class-combining selector (order-insensitive) first; the exact
  /// attribute match stays as a fallback in case the site renders an
  /// additional class in between.
  static String? _slowLinkHrefByDom(String html) {
    final document = parse(html);
    final paragraph =
        document.querySelector('p.mb-4.text-xl.font-bold') ??
        document.querySelector('p[class="mb-4 text-xl font-bold"]');
    return paragraph?.querySelector('a')?.attributes['href'];
  }

  // ────────────────────────────────────────────────────────────────
  // Phase 4: injectable Rust parse hooks. The host app sets these to
  // flutter_rust_bridge-backed implementations returning the SAME
  // models; when null (default) the Dart implementations above are
  // used as the fallback. Behavior must be identical either way —
  // test/parsers/anna_parsing_test.dart is the contract for both.
  // Only the two heavy HTML parsers are hooked; the light string/URL
  // helpers stay Dart (their cost is microseconds, below the FFI
  // round-trip).
  // ────────────────────────────────────────────────────────────────
  static Future<List<ArchiveBook>> Function(
    String html,
    String baseUrl,
    String fileType,
  )?
  searchResultsParseOverride;
  static Future<ArchiveBookDetails?> Function(
    String html,
    String url,
    String baseUrl,
  )?
  bookDetailsParseOverride;

  /// Hook-aware entry: Rust bridge when injected, Dart fallback
  /// otherwise. Call sites route through this instead of
  /// [parseSearchResults] directly.
  static Future<List<ArchiveBook>> parseSearchResultsH(
    String html, {
    required String baseUrl,
    String fileType = '',
  }) async => searchResultsParseOverride != null
      ? await searchResultsParseOverride!(html, baseUrl, fileType)
      : parseSearchResults(html, baseUrl: baseUrl, fileType: fileType);

  /// Hook-aware entry. Mirrors [parseSearchResultsH].
  static Future<ArchiveBookDetails?> parseBookDetailsH(
    String html, {
    required String url,
    required String baseUrl,
  }) async => bookDetailsParseOverride != null
      ? await bookDetailsParseOverride!(html, url, baseUrl)
      : parseBookDetails(html, url: url, baseUrl: baseUrl);
}
