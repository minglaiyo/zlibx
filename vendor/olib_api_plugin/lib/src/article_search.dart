import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// One article search hit: a "book" whose content type is `article`
/// (research papers, industry reports, journal scans — the site's
/// 文章 tab).
///
/// A dedicated model rather than [Book] on purpose: the card carries
/// fields Book has no slot for (`download`, `quality`) and the app
/// will need them — articles are downloaded through the card's
/// `/dl/…` path, not the eapi file endpoint that [Book] flows use.
/// Book itself stays untouched (it is shared by downloads, LibGen,
/// Anna's, ...) — the same rationale the full-text hit model uses.
class Article {
  final int id;
  final String title;

  /// Site-relative detail-page path (`/book/{hash}/{slug}.html`),
  /// exactly as the card carries it.
  final String? href;

  /// [href] resolved against the site base, or null.
  final String? url;

  /// The short URL hash from the `/book/{hash}/…` href (NOT the eapi
  /// hash — same distinction as everywhere else in this plugin).
  final String? hash;
  final String? author;
  final String? cover;
  final String? publisher;
  final int? year;
  final String? language;

  /// Always `pdf` in the capture (articles are scanned PDFs), but the
  /// attribute is passed through as-is.
  final String? extension;
  final String? filesizeString;
  final String? rating;

  /// The card's `quality` attribute (0–5, not the eapi quality score).
  final String? quality;

  /// The card's `download` attribute (`/dl/{token}`) resolved against
  /// the site base. Empty on removed cards — null here. This is the
  /// only download path the site offers for articles.
  final String? downloadPath;

  /// True when the card's `deleted` attribute is 1, 5 or 9: the site
  /// removed the file. Removed articles stay in the list (the site
  /// still shows them, greyed out) but [downloadPath] is empty.
  final bool removed;

  /// Why the article is removed, or null when it is not: `'copyright'`
  /// when `deleted` is 1, `'removed'` when it is 5 or 9. Same codes
  /// the full-text hit uses.
  final String? unavailableReason;

  const Article({
    required this.id,
    required this.title,
    this.href,
    this.url,
    this.hash,
    this.author,
    this.cover,
    this.publisher,
    this.year,
    this.language,
    this.extension,
    this.filesizeString,
    this.rating,
    this.quality,
    this.downloadPath,
    this.removed = false,
    this.unavailableReason,
  });
}

/// One page of article search results.
class ArticleSearchPage {
  final List<Article> articles;

  /// The total from the mode-tab text (`文章 (N)` / `Articles (N)`);
  /// falls back to [articles].length when the tab is missing (page
  /// shape change) — same fallback as the full-text parser.
  final int total;

  /// Pages from the `pagerOptions` script (`pagesTotal: N`) when
  /// present, else 1. The 2026-11-11 capture (2-result page) renders
  /// no pager data at all, so this stays a display-only hint.
  final int totalPages;

  const ArticleSearchPage({
    required this.articles,
    required this.total,
    required this.totalPages,
  });
}

/// One page of article search results, from the server-rendered
/// `/s/{query}?content_type=article` document.
///
/// Shape confirmed from the live capture 2026-11-11 (Firefox,
/// zh.z-library.sk, saved `金融分析` article search page): results
/// live in `#searchResultBox` as `<div class="book-item">` wrappers
/// around `<z-bookcard>` elements — the SAME card shape the
/// full-text page renders. Each card carries the metadata in its
/// attributes (`id`, `href`, `download`, `publisher`, `language`,
/// `year`, `extension`, `filesize`, `rating`, `quality`, `deleted`)
/// and the cover in a child `<img data-src>`; title/author are
/// `<div slot="title">` / `<div slot="author">`.
///
/// Skipped: the hidden `fit` template card (`.book-item[hidden]`,
/// counter 0, title/author equal to the query) and any other card
/// without a numeric `id`. A card with `deleted` in {1, 5, 9} is
/// KEPT with [Article.removed] set — the site still lists it.
///
/// Deliberately NOT read: the `user_token` attribute (a JWT carrying
/// the signed-in user's identity) and `termshash` (the eapi rejects
/// it; the fit card is detected via the wrapper's `hidden` /
/// counter 0, like the full-text parser does).
ArticleSearchPage parseArticleSearchPage(String html, {String? baseUrl}) {
  final doc = html_parser.parse(html);
  final cards = <dom.Element>[];
  // Cards live in `#searchResultBox`; scope the query to it so a card
  // elsewhere in the document cannot leak into the list. Fall back
  // to the whole document when the box is absent, so a page-shape
  // change does not silently return an empty list.
  final box = doc.querySelector('#searchResultBox');
  if (box != null) {
    for (final item in box.querySelectorAll('.book-item')) {
      if (item.attributes.containsKey('hidden')) continue;
      if (item.querySelector('.counter')?.text.trim() == '0') continue;
      final card = item.querySelector('z-bookcard');
      if (card == null) continue;
      cards.add(card);
    }
  } else {
    cards.addAll(doc.querySelectorAll('z-bookcard'));
  }
  final articles = <Article>[];
  for (final card in cards) {
    final id = int.tryParse(card.attributes['id']?.trim() ?? '');
    if (id == null) continue;
    final href = card.attributes['href']?.trim() ?? '';
    final img = card.querySelector('img');
    final coverRaw = img?.attributes['data-src']?.trim() ??
        img?.attributes['src']?.trim() ??
        '';
    final downloadRaw = card.attributes['download']?.trim() ?? '';
    final title =
        card.querySelector('div[slot="title"]')?.text.trim() ?? '';
    final author =
        card.querySelector('div[slot="author"]')?.text.trim() ?? '';
    final deleted = card.attributes['deleted']?.trim() ?? '';
    final removed =
        deleted == '1' || deleted == '5' || deleted == '9';
    final reason = !removed
        ? null
        : (deleted == '1' ? 'copyright' : 'removed');
    articles.add(
      Article(
        id: id,
        title: title,
        href: href.isEmpty ? null : href,
        url: href.isEmpty
            ? null
            : (baseUrl == null ? href : _resolveCardUrl(href, baseUrl)),
        hash: _hashFromHref(href),
        author: author.isEmpty ? null : author,
        cover: coverRaw.isEmpty
            ? null
            : (baseUrl == null
                  ? coverRaw
                  : _resolveCardUrl(coverRaw, baseUrl)),
        publisher: _attr(card, 'publisher'),
        year: int.tryParse(card.attributes['year']?.trim() ?? ''),
        language: _attr(card, 'language'),
        extension: _attr(card, 'extension'),
        filesizeString: _attr(card, 'filesize'),
        rating: _attr(card, 'rating'),
        quality: _attr(card, 'quality'),
        downloadPath: downloadRaw.isEmpty
            ? null
            : (baseUrl == null
                  ? downloadRaw
                  : _resolveCardUrl(downloadRaw, baseUrl)),
        removed: removed,
        unavailableReason: reason,
      ),
    );
  }
  final tabTotal = _parseArticleTotal(html);
  return ArticleSearchPage(
    articles: articles,
    total: tabTotal ?? articles.length,
    totalPages: _parseTotalPages(html),
  );
}

/// The query a results page's search form echoes back, or null when
/// the page carries no `q` input (or its value is empty).
///
/// Same guard the full-text search uses: the results form re-renders
/// the submitted query in its text field (`<input name="q">` — the
/// capture shows `value="金融分析"` on the article results page), so a
/// page answering a different listing echoes a different value (or
/// none), and the caller can tell a wrong page from the right one.
/// The value is entity-decoded by the parser, so it compares directly
/// against the submitted query string.
String? extractArticleSearchQuery(String html) {
  final doc = html_parser.parse(html);
  final value = doc
      .querySelector('input[name="q"]')
      ?.attributes['value']
      ?.trim();
  if (value == null || value.isEmpty) return null;
  return value;
}

String? _attr(dom.Element el, String name) {
  final value = el.attributes[name]?.trim();
  return value == null || value.isEmpty ? null : value;
}

/// Book hash from a `/book/{hash}/{slug}.html` href, or null when the
/// href does not have that shape (same rule as the full-text parser's
/// `_hashFromHref`, which lives in another library and cannot be
/// shared here).
String? _hashFromHref(String href) {
  final segments = Uri.tryParse(href)?.pathSegments ?? const <String>[];
  if (segments.length >= 2 && segments[0] == 'book') {
    final hash = segments[1];
    return hash.isEmpty ? null : hash;
  }
  return null;
}

String _resolveCardUrl(String raw, String baseUrl) {
  if (raw.startsWith('http://') || raw.startsWith('https://')) {
    return raw;
  }
  if (raw.startsWith('//')) return 'https:$raw';
  if (raw.startsWith('/')) return '$baseUrl$raw';
  return raw;
}

/// The total from the mode-tab text. The active tab renders the count
/// in parentheses, e.g. `文章&nbsp;(2)` on zh mirrors; non-zh mirrors
/// use the English label. The count renders with a non-breaking space
/// (`&nbsp;` in the raw HTML), so the pattern accepts raw whitespace,
/// `&nbsp;` and `&#160;` alike, and large totals render with a
/// trailing `+` — the count is the digits before it. Null when the
/// tab is absent (the caller falls back to the parsed card count).
int? _parseArticleTotal(String html) {
  final match = RegExp(
    r'(?:文章|Articles)(?:\s|&nbsp;|&#160;)*\((\d+)\+?\)',
  ).firstMatch(html);
  if (match == null) return null;
  return int.tryParse(match.group(1) ?? '');
}

/// Pages from the `pagerOptions` script (`pagesTotal: N`) when
/// present, else 1. Same rule as the full-text parser.
int _parseTotalPages(String html) {
  final match = RegExp(r'pagesTotal\s*:\s*(\d+)').firstMatch(html);
  final pages = match == null
      ? null
      : int.tryParse(match.group(1) ?? '');
  return pages == null || pages < 1 ? 1 : pages;
}

/// Injectable Rust parse hook (phase 3). The host app sets this to a
/// flutter_rust_bridge-backed implementation returning the SAME
/// [ArticleSearchPage] model; when null (default) the Dart
/// implementation above is used as the fallback. Behavior must be
/// identical either way — test/parsers/article_search_test.dart is
/// the contract for both.
Future<ArticleSearchPage> Function(String html, String? baseUrl)?
articleParseOverride;
