import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'book.dart';

/// The error string [ZLibraryFullText.searchFullText] fails with when
/// the session's full-text token could not be fetched (the token page
/// did not carry one, or the session is gone). The app matches on this
/// exact string to show the localized "full-text search unavailable"
/// message instead of the raw error — keep it stable.
const fulltextTokenUnavailable = 'fulltext token unavailable';

/// One highlighted (or plain) run inside a [FullTextHit.snippet].
class FullTextSnippetPart {
  /// The text, with runs of whitespace folded to a single space.
  final String text;

  /// True when this run was wrapped in `<em>` on the page (the
  /// matched query text).
  final bool highlighted;

  const FullTextSnippetPart({required this.text, required this.highlighted});
}

/// One full-text search hit: the book plus the matching passage.
///
/// The book is the same [Book] the rest of the app uses (parsed from
/// the card's attributes, exactly like [parseBooklistDetailBooks]);
/// the snippet and the availability flag live here so [Book] itself
/// stays untouched (it is shared by downloads, LibGen, Anna's, ...).
class FullTextHit {
  final Book book;

  /// The matching passage, split on `<em>` into highlighted/plain
  /// runs. Empty when the card carried no `.ft_highlight` block.
  final List<FullTextSnippetPart> snippet;

  /// True when the card's `deleted` attribute is 1, 5 or 9: the
  /// site removed the file (or took it down on a copyright
  /// complaint). Removed hits are shown greyed and are not
  /// downloadable, but still open the detail page (site behaviour).
  final bool removed;

  /// Why the hit is removed, or null when it is not removed:
  /// `'copyright'` when `deleted` is 1, `'removed'` when it is 5 or
  /// 9. The UI maps these codes to localized labels.
  final String? unavailableReason;

  const FullTextHit({
    required this.book,
    required this.snippet,
    required this.removed,
    this.unavailableReason,
  });
}

/// One page of full-text search results.
class FullTextSearchPage {
  final List<FullTextHit> hits;

  /// The total from the tab text (`全文检索 (N)`); falls back to
  /// [hits].length when the tab is missing (page shape change).
  final int total;

  /// Pages from `pagerOptions.pagesTotal` when present, else 1.
  final int totalPages;

  const FullTextSearchPage({
    required this.hits,
    required this.total,
    required this.totalPages,
  });
}

/// The session's full-text token from a search page's HTML, or null
/// when the page carries none (or the value is not an 8-hex token).
///
/// The token lives in the search form's hidden field
/// (`<input name="token">`); it is a per-session value rendered by
/// the server — never hardcode one. The site's mode-switch script
/// carries the same value, which is how the two captures confirm it
/// is stable within a session (not per-query).
String? extractFulltextToken(String html) {
  final doc = html_parser.parse(html);
  final value = doc
      .querySelector('input[name="token"]')
      ?.attributes['value']
      ?.trim();
  if (value == null || value.isEmpty) return null;
  if (!RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(value)) return null;
  return value;
}

/// The query a results page's search form echoes back, or null when
/// the page carries no `q` input (or its value is empty).
///
/// The results page renders the submitted query in the form's text
/// field (`<input name="q">`); a page answering a different query —
/// the default listing the server returns for a stale token —
/// echoes a different value (or none), which is how the caller
/// tells a wrong page from the right one. The value is entity-decoded
/// by the parser, so it compares directly against the submitted
/// query string.
String? extractFulltextQuery(String html) {
  final doc = html_parser.parse(html);
  final value = doc
      .querySelector('input[name="q"]')
      ?.attributes['value']
      ?.trim();
  if (value == null || value.isEmpty) return null;
  return value;
}

/// One page of full-text search results, from the server-rendered
/// `/fulltext` document.
///
/// Shape confirmed from the live capture 2026-11-11 (Firefox,
/// zh.z-library.sk, saved `/fulltext/{query}` page): results live in
/// `#searchResultBox` as `<div class="book-item">` wrappers around
/// `<z-bookcard>` elements; each card carries the book in its
/// attributes (`id`, `href`, `publisher`, `language`, `year`,
/// `extension`, `filesize`, `rating`, `download`) and the cover in a
/// child `<img data-src>`; the title/author are `<div
/// slot="title">` / `<div slot="author">`. The matching passage is
/// `<div slot="extend"> .hulltext .ft_highlight .ft_highlight_part`,
/// with the matched text wrapped in `<em>` (one `<em>` for
/// `type=phrase`; `type=words` may yield several). The `user_token`
/// attribute (a JWT carrying the signed-in user's identity) is
/// deliberately NOT read. The count lives only in the tab text
/// (`全文检索 (N)`) — never use the card count as the total.
///
/// Skipped: the hidden `fit` template card (`.book-item[hidden]`,
/// counter 0, no `termshash`, title/author equal to the query) and
/// `<z-promotion>` ad slots (no `z-bookcard` inside, so they never
/// yield a card). A card with `deleted` in {1, 5, 9} is KEPT with
/// [FullTextHit.removed] set — the site still lists it, greyed out.
FullTextSearchPage parseFullTextSearchPage(String html, {String? baseUrl}) {
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
  final hits = <FullTextHit>[];
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
    hits.add(
      FullTextHit(
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
        snippet: _parseSnippet(card),
        removed: removed,
        unavailableReason: reason,
      ),
    );
  }
  final tabTotal = _parseTotal(html);
  return FullTextSearchPage(
    hits: hits,
    total: tabTotal ?? hits.length,
    totalPages: _parseTotalPages(html),
  );
}

String? _attr(dom.Element el, String name) {
  final value = el.attributes[name]?.trim();
  return value == null || value.isEmpty ? null : value;
}

/// Book hash from a `/book/{hash}/{slug}.html` href, or null when the
/// href does not have that shape (same rule as the booklist parser's
/// `_hashFromBookHref`, which lives in another library and cannot be
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

/// The matching passage: `.hulltext .ft_highlight .ft_highlight_part`,
/// split on `<em>` into highlighted/plain runs. Runs of whitespace
/// (the PDF hard line breaks) fold to a single space; leading/trailing
/// whitespace is trimmed only at the passage edges so the spacing
/// between runs is preserved.
List<FullTextSnippetPart> _parseSnippet(dom.Element card) {
  final part = card.querySelector(
    '.hulltext .ft_highlight .ft_highlight_part',
  );
  if (part == null) return const [];
  final parts = <FullTextSnippetPart>[];
  for (final node in part.nodes) {
    final isEm = node is dom.Element && node.localName == 'em';
    final text = (node.text ?? '').replaceAll(RegExp(r'\s+'), ' ');
    if (text.trim().isEmpty) continue;
    parts.add(
      FullTextSnippetPart(text: text, highlighted: isEm),
    );
  }
  if (parts.isEmpty) return const [];
  final first = parts.first;
  final last = parts.last;
  return [
    FullTextSnippetPart(
      text: first.text.trimLeft(),
      highlighted: first.highlighted,
    ),
    if (parts.length > 2) ...parts.sublist(1, parts.length - 1),
    if (parts.length > 1)
      FullTextSnippetPart(
        text: last.text.trimRight(),
        highlighted: last.highlighted,
      ),
  ];
}

/// The total from the tab text (`全文检索 (N)`). The tab renders the
/// count with a non-breaking space (`&nbsp;` in the raw HTML), so the
/// pattern accepts raw whitespace, `&nbsp;` and `&#160;` alike. Large
/// totals render with a trailing `+` (`全文检索 (150+)`) — the count
/// is the digits before it. Null when the tab is absent.
int? _parseTotal(String html) {
  final match = RegExp(
    r'全文检索(?:\s|&nbsp;|&#160;)*\((\d+)\+?\)',
  ).firstMatch(html);
  if (match == null) return null;
  return int.tryParse(match.group(1) ?? '');
}

/// Pages from the `pagerOptions` script (`pagesTotal: N`) when
/// present, else 1.
int _parseTotalPages(String html) {
  final match = RegExp(r'pagesTotal\s*:\s*(\d+)').firstMatch(html);
  final pages = match == null
      ? null
      : int.tryParse(match.group(1) ?? '');
  return pages == null || pages < 1 ? 1 : pages;
}

/// Injectable Rust parse hook (phase 2 migration). The host app sets
/// this to a flutter_rust_bridge-backed implementation returning the
/// SAME [FullTextSearchPage] model; when null (default) the Dart
/// implementation above is used as the fallback. Behavior must be
/// identical either way — test/parsers/fulltext_test.dart is the
/// contract for both.
Future<FullTextSearchPage> Function(String html, String? baseUrl)?
fulltextParseOverride;
