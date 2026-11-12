import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'book.dart';

/// One book on a category page: the parsed [Book] plus the two
/// per-card flags the category screen needs.
///
/// `isFavorite` is the card's `favorite` attribute (`"1"` when the
/// signed-in user has favourited the book; the category browse is the
/// only list that carries it). [unavailableReason] mirrors the
/// full-text hit's: `'copyright'` when `deleted="1"`, `'removed'`
/// when `deleted` is `5` or `9`, null otherwise. A removed book is
/// KEPT in the list (the site still lists it, greyed out) — the
/// screen greys it and blocks its download button instead of
/// dropping it.
class CategoryBook {
  final Book book;
  final bool isFavorite;
  final String? unavailableReason;

  const CategoryBook({
    required this.book,
    this.isFavorite = false,
    this.unavailableReason,
  });

  bool get removed => unavailableReason != null;
}

/// One parsed category page: the books on it and, when the page
/// carries it, the total page count from `pagerOptions.pagesTotal`.
///
/// [totalPages] is null when the page has no inline `pagerOptions`
/// definition (a small category's page carries none) — never invent
/// a total. The provider falls back to the first page's card count
/// as the effective page size in that case.
class CategoryPage {
  final List<CategoryBook> books;
  final int? totalPages;

  /// The slug of the page's search form action
  /// (`/category/{id}/{slug}/s/`). The server only serves the
  /// in-category search at the slugged URL — the bare
  /// `/category/{id}/s/` answers an empty page (device-proven
  /// 2026-11-12: the WebView solver loaded the bare URL and parsed
  /// 0 cards while the browse parsed 50) — so a search must pass
  /// this slug (see `searchInCategory`). Null when the page
  /// carries no search form.
  final String? searchSlug;

  const CategoryPage({required this.books, this.totalPages, this.searchSlug});
}

/// Parse a `/category/{id}` (or `/category/{id}/{slug}/s/`) document
/// into its books and page count.
///
/// Shape confirmed from the live captures 2026-11-11 (Firefox,
/// zh.z-library.sk): results live in `#searchResultBox` as `<div
/// class="book-item">` wrappers around `&lt;z-bookcard&gt;` elements — the
/// same shape as the full-text results page, so the scoping rules
/// are the same as [parseFullTextSearchPage]'s. Each card carries the
/// book in its attributes (`id`, `href`, `publisher`, `language`,
/// `year`, `extension`, `filesize`, `rating`, `download`) and the
/// cover in a child `<img data-src>`; the title/author are `<div
/// slot="title">` / `<div slot="author">`. The `user_token`
/// attribute (a JWT carrying the signed-in user's identity) is
/// deliberately NOT read.
///
/// Skipped: the hidden `fit` template card (`.book-item[hidden]`,
/// counter 0, no `termshash`) and `<z-promotion>` ad slots (no
/// `z-bookcard` inside, so they never yield a card). A card with
/// `deleted` in {1, 5, 9} is KEPT with [CategoryBook.removed] set.
CategoryPage parseCategoryBooksPage(String html, {String? baseUrl}) {
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
  final books = <CategoryBook>[];
  for (final card in cards) {
    // The hidden fit template outside a `.book-item` wrapper (see the
    // fallback above): no `termshash` and class `fit`.
    final termshash = card.attributes['termshash']?.trim() ?? '';
    if (termshash.isEmpty && card.classes.contains('fit')) continue;
    final id = int.tryParse(card.attributes['id']?.trim() ?? '');
    if (id == null) continue;
    final href = card.attributes['href']?.trim() ?? '';
    final img = card.querySelector('img');
    final coverRaw = img?.attributes['data-src']?.trim() ??
        img?.attributes['src']?.trim() ??
        '';
    final title = card.querySelector('div[slot="title"]')?.text.trim() ?? '';
    final author =
        card.querySelector('div[slot="author"]')?.text.trim() ?? '';
    final deleted = card.attributes['deleted']?.trim() ?? '';
    final removed = deleted == '1' || deleted == '5' || deleted == '9';
    final reason =
        !removed ? null : (deleted == '1' ? 'copyright' : 'removed');
    books.add(
      CategoryBook(
        book: Book(
          id: id,
          title: title,
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
          interestScore: _attr(card, 'rating'),
          readOnlineUrl: _attr(card, 'read'),
        ),
        isFavorite: card.attributes['favorite']?.trim() == '1',
        unavailableReason: reason,
      ),
    );
  }
  // The search form's action carries the slugged search URL. Read
  // the slug off it (decoded, so the path builder re-encodes it
  // exactly once): the server only serves the in-category search
  // at the slugged URL, and the bare `/category/{id}/s/` answers
  // an empty page (device-proven 2026-11-12). Any form whose action
  // matches the search pattern counts; the form id is not relied
  // on.
  String? searchSlug;
  for (final form in doc.querySelectorAll('form')) {
    final action = form.attributes['action'] ?? '';
    final slugMatch =
        RegExp(r'/category/\d+/([^/]+)/s/').firstMatch(action);
    if (slugMatch != null) {
      try {
        searchSlug = Uri.decodeComponent(slugMatch.group(1)!);
      } catch (_) {
        searchSlug = slugMatch.group(1);
      }
      break;
    }
  }
  return CategoryPage(
    books: books,
    totalPages: _parseCategoryTotalPages(html),
    searchSlug: searchSlug,
  );
}

String? _attr(dom.Element el, String name) {
  final value = el.attributes[name]?.trim();
  return value == null || value.isEmpty ? null : value;
}

/// Book hash from a `/book/{hash}/{slug}.html` href, or null when the
/// href does not have that shape (same rule as the full-text
/// parser's `_hashFromHref`, which lives in another library and
/// cannot be shared here).
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

/// Total pages from the inline `pagerOptions.pagesTotal` definition,
/// or null when the page carries none. A page without it is a small
/// category (or a shape change) — the caller must not invent a total
/// from the card count.
int? _parseCategoryTotalPages(String html) {
  final match = RegExp(r'pagesTotal\s*:\s*(\d+)').firstMatch(html);
  final pages = match == null ? null : int.tryParse(match.group(1) ?? '');
  return pages == null || pages < 1 ? null : pages;
}
