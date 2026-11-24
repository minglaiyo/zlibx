import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'book.dart';

/// One page of the site's book search (`/s/{query}`), parsed from its
/// HTML.
///
/// A dedicated result type rather than a bare `List<Book>` because the
/// page carries two things the eapi search payload does not: the
/// per-card `deleted` flag (the screen greys those cards out — same
/// [unavailableReasons] map the category path produces) and the
/// pager's own page count, which must not be invented from the card
/// count.
class BookSearchPage {
  final List<Book> books;

  /// Why a listed book is unavailable, keyed by [Book.id] (`'copyright'`
  /// for `deleted="1"`, `'removed'` for 5/9). Empty when every card is
  /// live — the screen only reads this to grey cards out.
  final Map<int, String> unavailableReasons;

  /// Pages from the `pagerOptions` script (`pagesTotal: N`), or null
  /// when the page carries none. Null means "unknown", never 1: the
  /// caller pages until a short page instead of stopping early (the
  /// same rule [CategoryPage.totalPages] follows).
  final int? totalPages;

  /// The books-tab count (`书籍 (150+)` → 150), null when the tab is
  /// absent. Display only — the site caps it at a `+` bucket, so it is
  /// never used for paging.
  final int? total;

  const BookSearchPage({
    required this.books,
    this.unavailableReasons = const {},
    this.totalPages,
    this.total,
  });
}

/// Parse a `/s/{query}` book-results document into its books.
///
/// Shape confirmed from the live capture 2026-11-24 (bookroom.lifestyle,
/// logged-in session, query `三体`, saved as 187 KB of real HTML): the
/// results live in `#searchResultBox` as `<div class="book-item">`
/// wrappers around `<z-bookcard>` elements — the SAME card shape the
/// category and article pages render, and the same attribute set:
/// `id`, `isbn`, `termshash`, `href`, `download`, `deleted`,
/// `publisher`, `language`, `year`, `extension`, `filesize`, `rating`,
/// `quality`, `user_token`, `contentTypeParam`. Title/author are the
/// `<div slot="title">` / `<div slot="author">` children and the cover
/// is an `<img data-src>`. 51 cards render per page.
///
/// Field notes from that capture (they are NOT the eapi payload):
/// * `href` is `/book/{hash}/{slug}.html` and its hash is the site's
///   10-character short hash. The eapi detail endpoints want a
///   different, 6-character hash that the HTML does not carry
///   anywhere, so a book parsed from here can never be fed to
///   `GET /eapi/book/{id}/{hash}` — the callers must use the
///   HTML-only channels instead.
/// * `filesize` is already a display string (`2.48 MB`), so it fills
///   [Book.filesizeString] and never [Book.filesize] (bytes).
/// * `download` is a per-format `/dl/{token}` path whose token is
///   neither the card hash nor the eapi hash, and it is the only
///   download address the HTML offers.
/// * `rating` is the interest score rendered as `5.0`; `quality`
///   (0–5) is deliberately NOT mapped onto [Book.ratingQuality],
///   which documents the detail page's rendered decimal.
///
/// Skipped: the hidden `fit` template card (`.book-item[hidden]`,
/// counter 0, no `termshash`) and `<z-promotion>` ad slots (no card
/// inside). A card with `deleted` in {1, 5, 9} is KEPT with its reason
/// recorded — the site still lists removed books.
///
/// Deliberately NOT read: `user_token` (a JWT carrying the signed-in
/// user's identity) and `termshash` (the eapi rejects it as a hash) —
/// same rule as every other card parser in this plugin.
BookSearchPage parseSearchBooksPage(String html, {String? baseUrl}) {
  final doc = html_parser.parse(html);
  final cards = <dom.Element>[];
  // Scope to `#searchResultBox` so a card elsewhere in the document
  // (a sidebar recommendation, an ad) cannot leak into the results.
  // Fall back to the whole document when the box is absent so a
  // page-shape change yields an empty list loudly rather than
  // silently dropping real cards.
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
  final books = <Book>[];
  final unavailable = <int, String>{};
  for (final card in cards) {
    // The hidden fit template when it sits outside a `.book-item`
    // wrapper (the fallback branch above): no `termshash`, class `fit`.
    final termshash = card.attributes['termshash']?.trim() ?? '';
    if (termshash.isEmpty && card.classes.contains('fit')) continue;
    final id = int.tryParse(card.attributes['id']?.trim() ?? '');
    if (id == null) continue;
    final href = card.attributes['href']?.trim() ?? '';
    final img = card.querySelector('img');
    final coverRaw = img?.attributes['data-src']?.trim() ??
        img?.attributes['src']?.trim() ??
        '';
    final downloadRaw = card.attributes['download']?.trim() ?? '';
    final title = card.querySelector('div[slot="title"]')?.text.trim() ?? '';
    final author =
        card.querySelector('div[slot="author"]')?.text.trim() ?? '';
    final isbn = _attr(card, 'isbn');
    final deleted = card.attributes['deleted']?.trim() ?? '';
    final removed = deleted == '1' || deleted == '5' || deleted == '9';
    books.add(
      Book(
        id: id,
        // A card with no title text would render an empty row; the
        // site always fills the slot, so an empty title means the
        // shape changed and the id alone still identifies the book.
        title: title,
        hash: _hashFromHref(href),
        href: href.isEmpty ? null : href,
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
        interestScore: _attr(card, 'rating'),
        isbn13: isbn != null && isbn.length == 13 ? isbn : null,
        isbn10: isbn != null && isbn.length == 10 ? isbn : null,
        downloadPath: downloadRaw.isEmpty
            ? null
            : (baseUrl == null
                  ? downloadRaw
                  : _resolveCardUrl(downloadRaw, baseUrl)),
      ),
    );
    if (removed) {
      unavailable[id] = deleted == '1' ? 'copyright' : 'removed';
    }
  }
  return BookSearchPage(
    books: books,
    unavailableReasons: unavailable,
    totalPages: _parseTotalPages(html),
    total: _parseBooksTabTotal(html),
  );
}

/// The query a book results page echoes back in its search form
/// (`<input name="q" value="三体">`), or null when the page carries no
/// non-empty `q` value.
///
/// The wrong-page guard the article and full-text searches also apply:
/// the results form re-renders the submitted query, so a page that
/// answered a different listing (or the bare search form) echoes a
/// different value or none. The value is entity-decoded by the parser,
/// so it compares directly against the submitted query.
String? extractSearchBooksQuery(String html) {
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
/// href does not have that shape. This is the site's short hash, never
/// the eapi one (see the field notes on [parseSearchBooksPage]).
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

/// The books-tab count. The active tab renders it in parentheses —
/// `书籍&nbsp;(150+)` on zh mirrors, `Books (N)` on others, `Книги (N)`
/// on ru — with a non-breaking space and a trailing `+` on large
/// totals, so the count is the digits before the `+`. Null when the
/// tab is absent (the caller shows the parsed card count instead).
int? _parseBooksTabTotal(String html) {
  final match = RegExp(
    r'(?:书籍|Books|Книги)(?:\s|&nbsp;|&#160;)*\((\d+)\+?\)',
  ).firstMatch(html);
  if (match == null) return null;
  return int.tryParse(match.group(1) ?? '');
}

/// Pages from the inline `pagerOptions` definition, or null when the
/// page carries none. Same "never invent a total" rule as
/// `_parseCategoryTotalPages`.
int? _parseTotalPages(String html) {
  final match = RegExp(r'pagesTotal\s*:\s*(\d+)').firstMatch(html);
  final pages = match == null ? null : int.tryParse(match.group(1) ?? '');
  return pages == null || pages < 1 ? null : pages;
}

/// Injectable Rust parse hook. See booklist.dart's hooks for the
/// contract; test/parsers/search_html_test.dart is the baseline for
/// both implementations.
Future<BookSearchPage> Function(String html, String? baseUrl)?
    searchBooksParseOverride;

/// Hook-aware entry. Mirrors parseCategoryBooksPageH.
Future<BookSearchPage> parseSearchBooksPageH(
  String html, {
  String? baseUrl,
}) async =>
    searchBooksParseOverride != null
        ? await searchBooksParseOverride!(html, baseUrl)
        : parseSearchBooksPage(html, baseUrl: baseUrl);
