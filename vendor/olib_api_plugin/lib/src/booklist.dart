import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'book.dart';

/// One Z-Library booklist (the website's "booklists" feature: a named,
/// shareable collection of books with an author and a book count).
///
/// Browsing public booklists, the signed-in user's own booklists, and
/// the books inside one booklist, plus creating, editing, deleting and
/// favoriting lists and adding/removing books
/// (`ZLibraryApi.createBooklist` and friends).
class Booklist {
  /// The numeric id from the list URL (`/booklists/{id}/...`).
  final String id;

  /// List name (`topic` attribute on the list element).
  final String name;
  final String description;

  /// The creator's username (`author` attribute), or ''.
  ///
  /// NOTE: an older revision read `authorprofile` (the profile path)
  /// into this field, so cards showed e.g. "/profile/35899435/5a9053"
  /// as the author. The site carries both: `author` is the display
  /// name, `authorprofile` is the profile path (see [authorProfile]).
  /// The `author` attribute wins; `authorprofile` is only a fallback
  /// for a page shape that carries no `author` attribute.
  final String author;

  /// The creator's profile path (`authorprofile` attribute), or ''.
  /// Empty when the page did not carry one.
  final String authorProfile;

  /// The creator's avatar URL (`authoravatar` attribute), or ''.
  final String authorAvatar;

  /// Book count (`quantity` attribute), null when the page did not say.
  final int? count;

  /// View count (`views` attribute), or ''.
  final String views;

  /// Comment count (`comments` attribute), or ''.
  final String comments;

  /// List color (`color` attribute, 0–5), null when the page did not
  /// say. The site uses -1 for lists that carry no color (not the
  /// signed-in user's own): callers treat a negative value as "no
  /// color". See [booklistColors] for the six gradients.
  final int? color;

  /// True when the element carries the `private` attribute (a private
  /// list shows a lock on the site).
  final bool isPrivate;

  /// True when the element carries the `favorite` attribute (the
  /// signed-in user favorited this list; the site shows a filled
  /// heart).
  final bool isFavorite;

  /// Cover thumbnail (first carousel image's `data-src`), or ''.
  final String coverUrl;

  /// Absolute URL of the list page on the mirror.
  final String url;

  /// Books from the list page's own carousel (`<z-cover>` children:
  /// id, title, author, cover, hash from the wrapping link). The
  /// detail screen paints these instantly — no fetch — and only
  /// fetches the detail page when the carousel is short of the list
  /// total. Empty when the page carried no carousel (e.g. a list
  /// created through the API response parser).
  final List<Book> previewBooks;

  const Booklist({
    required this.id,
    required this.name,
    this.description = '',
    this.author = '',
    this.authorProfile = '',
    this.authorAvatar = '',
    this.count,
    this.views = '',
    this.comments = '',
    this.color,
    this.isPrivate = false,
    this.isFavorite = false,
    this.coverUrl = '',
    required this.url,
    this.previewBooks = const [],
  });

  /// Build from one `<z-booklist>` element of a `/booklists` (or
  /// `/booklists/my`) list page. Attribute shapes follow the public
  /// sertraline/zlibrary client (read as a shape reference only — no
  /// code copied): `topic` = name, `href` = list URL, `description`,
  /// `authorprofile`, `quantity`, `views`; the cover is the first
  /// carousel image's `data-src`. Returns null when the element has no
  /// usable name or id.
  static Booklist? fromElement(dom.Element el, {required String baseUrl}) {
    final name = el.attributes['topic']?.trim();
    if (name == null || name.isEmpty) return null;
    final href = el.attributes['href']?.trim() ?? '';
    // The live page carries the numeric id directly on the element
    // (id="4088695"), and its href uses the SINGULAR /booklist/{id}/...
    // shape. The old code only looked for a 'booklists' segment in the
    // href, so every real list was dropped and the screen showed "no
    // booklists" even when the page loaded fine (verified against the
    // live /booklists/my HTML 2026-11-06).
    final idAttr = el.attributes['id']?.trim();
    final id = (idAttr != null && RegExp(r'^\d+$').hasMatch(idAttr))
        ? idAttr
        : _idFromHref(href);
    if (id == null) return null;
    var coverUrl = '';
    // The cover is the first carousel image's data-src: prefer the
    // first <z-cover>'s <img> so an unrelated image elsewhere in the
    // element (an avatar or icon) cannot win the scan. Fall back to
    // the whole-element scan only when there is no carousel at all.
    final firstCover = el.querySelector('z-cover');
    final firstSrc =
        firstCover?.querySelector('img')?.attributes['data-src']?.trim() ??
        '';
    if (firstSrc.isNotEmpty) {
      coverUrl = _resolveUrl(firstSrc, baseUrl);
    } else {
      for (final img in el.querySelectorAll('img')) {
        final src = img.attributes['data-src']?.trim() ?? '';
        if (src.isNotEmpty) {
          coverUrl = _resolveUrl(src, baseUrl);
          break;
        }
      }
    }
    // The carousel already carries every book the list page shows:
    // each <z-cover> has the numeric id, title and author as
    // attributes, the cover in a child <img data-src>, and the book
    // hash in the wrapping <a href="/book/{hash}/..."> (verified
    // against the live /booklists/my HTML 2026-11-06 — the 001 card
    // carries all 5 of its books this way). The detail screen paints
    // these instantly instead of fetching the detail page.
    final previewBooks = <Book>[];
    for (final cover in el.querySelectorAll('z-cover')) {
      final bookId = int.tryParse(cover.attributes['id']?.trim() ?? '');
      if (bookId == null) continue;
      final img = cover.querySelector('img');
      final coverRaw = img?.attributes['data-src']?.trim() ??
          img?.attributes['src']?.trim() ??
          '';
      dom.Element? linkEl;
      var node = cover.parent;
      while (node is dom.Element) {
        if (node.localName == 'a') {
          linkEl = node;
          break;
        }
        node = node.parent;
      }
      previewBooks.add(
        Book(
          id: bookId,
          title: cover.attributes['title']?.trim() ?? '',
          hash: _hashFromBookHref(linkEl?.attributes['href'] ?? ''),
          author: _cardAttr(cover, 'author'),
          cover: coverRaw.isEmpty ? null : _resolveUrl(coverRaw, baseUrl),
        ),
      );
    }
    return Booklist(
      id: id,
      name: name,
      description: el.attributes['description']?.trim() ?? '',
      author: _authorName(el),
      authorProfile: el.attributes['authorprofile']?.trim() ?? '',
      authorAvatar: _resolveUrl(
        el.attributes['authoravatar']?.trim() ?? '',
        baseUrl,
      ),
      count: int.tryParse(el.attributes['quantity']?.trim() ?? ''),
      views: el.attributes['views']?.trim() ?? '',
      comments: el.attributes['comments']?.trim() ?? '',
      color: int.tryParse(el.attributes['color']?.trim() ?? ''),
      isPrivate: el.attributes.containsKey('private'),
      isFavorite: el.attributes.containsKey('favorite'),
      coverUrl: coverUrl,
      url: _resolveUrl(href, baseUrl),
      previewBooks: previewBooks,
    );
  }

  /// The creator's display name: the `author` attribute when present,
  /// else the `authorprofile` attribute (an older page shape carried
  /// only that one). The profile path is a path, not a name, so it is
  /// only a fallback — never the first choice.
  static String _authorName(dom.Element el) {
    final name = el.attributes['author']?.trim() ?? '';
    if (name.isNotEmpty) return name;
    return el.attributes['authorprofile']?.trim() ?? '';
  }

  /// The list id is the path segment after `/booklists/` — or the live
  /// site's singular `/booklist/` (`/booklist/4088695/...` -> `4088695`).
  static String? _idFromHref(String href) {
    if (href.isEmpty) return null;
    final segments = Uri.tryParse(href)?.pathSegments ?? const <String>[];
    var at = segments.indexOf('booklists');
    if (at < 0) at = segments.indexOf('booklist');
    if (at < 0 || at + 1 >= segments.length) return null;
    final id = segments[at + 1];
    return id.isEmpty ? null : id;
  }

  static String _resolveUrl(String raw, String baseUrl) {
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return raw;
    }
    if (raw.startsWith('//')) return 'https:$raw';
    if (raw.startsWith('/')) return '$baseUrl$raw';
    return raw;
  }
}

/// One entry of `GET /papi/booklist/current-user/{bookId}`: one of
/// the signed-in user's booklists plus whether [bookId] is in it.
/// [readlistBookId] is the per-(book, list) membership-row id (what
/// remove-book takes), null when the book is not in the list.
class BooklistMembership {
  /// The list's numeric id.
  final int booklistId;

  /// The list's title, or '' when the response did not carry one.
  final String title;

  /// The membership-row id, or null when the book is not in the list.
  final int? readlistBookId;

  const BooklistMembership({
    required this.booklistId,
    this.title = '',
    this.readlistBookId,
  });

  /// True when the book is in this list.
  bool get isMember => readlistBookId != null;
}

/// One page of booklist search results.
///
/// [totalPages] is 0 when the page did not carry a page count — callers
/// then page until an empty page arrives.
class BooklistsPage {
  final List<Booklist> lists;
  final int totalPages;

  const BooklistsPage({required this.lists, this.totalPages = 0});
}

/// Books inside one booklist, from
/// `GET /papi/booklist/{id}/get-books/{page}`.
class BooklistBooksPage {
  final List<Book> books;
  final int totalPages;

  const BooklistBooksPage({required this.books, this.totalPages = 1});
}

/// Parse a `/booklists` (or `/booklists/my`) list page (HTML) into a
/// [BooklistsPage]. A page with no `<z-booklist>` elements parses to an
/// empty list (covers both "nothing found" and past-the-end pages).
/// The page count lives in an inline script
/// (`var pagerOptions = {... pagesTotal: N, ...}`); absent means unknown.
BooklistsPage parseBooklistsPage(String html, {required String baseUrl}) {
  final doc = html_parser.parse(html);
  final lists = doc
      .querySelectorAll('z-booklist')
      .map((el) => Booklist.fromElement(el, baseUrl: baseUrl))
      .whereType<Booklist>()
      .toList();
  var totalPages = 0;
  final match = RegExp(r'pagesTotal:\s*(\d+)').firstMatch(html);
  if (match != null) totalPages = int.tryParse(match.group(1)!) ?? 0;
  return BooklistsPage(lists: lists, totalPages: totalPages);
}

/// Booklists on one user's profile page, from the server-rendered
/// `<z-booklist>` elements inside `<div z-tab="booklists">`.
///
/// The profile page (`GET /profile/{userId}/{hash}`) is one HTML
/// document carrying every tab; the booklists tab holds the same
/// `<z-booklist>` shape as the `/booklists` list pages (see
/// [Booklist.fromElement]), including the preview-cover carousel.
/// A profile with no booklists — or a page without the tab at all —
/// parses to an empty list.
///
/// The tab server-renders at most 10 lists per document: users with
/// more get a paginator (`.paginator_booklists`) and the rest live on
/// `/profile/{userId}/{hash}/booklists?page=N` documents of the same
/// shape (live-verified 2026-11-21). See
/// [parseUserProfileBooklistsPagesTotal] for the page count and
/// `ZLibraryBooklists.getUserProfileBooklistsPage` for the fetch.
List<Booklist> parseUserProfileBooklists(
  String html, {
  required String baseUrl,
}) {
  final doc = html_parser.parse(html);
  final tab = doc.querySelector('div[z-tab="booklists"]');
  if (tab == null) return const [];
  return tab
      .querySelectorAll('z-booklist')
      .map((el) => Booklist.fromElement(el, baseUrl: baseUrl))
      .whereType<Booklist>()
      .toList();
}

/// One document of a user's profile booklists: the parsed
/// `<z-booklist>` rows plus the paginator's page count. [pagesTotal]
/// is 1 unless the document carries the booklists paginator — the
/// site renders at most 10 lists per document (issue #11: the profile
/// page showed only the first 10).
class UserProfileBooklistsPage {
  final List<Booklist> lists;

  /// Total number of paginated documents, from
  /// [parseUserProfileBooklistsPagesTotal] on the same HTML.
  final int pagesTotal;

  const UserProfileBooklistsPage({
    required this.lists,
    this.pagesTotal = 1,
  });
}

/// The page count of a profile page's booklists tab, from the tab's
/// paginator (`DIV.paginator.paginator_booklists`, live-verified
/// 2026-11-21): its links carry `?page=N` up to the last page (the
/// "Last" link), so the largest `page=` value across them is the
/// total. A document without the paginator — the profile document of
/// a user with ≤ 10 lists — is one page. The same shape holds on the
/// `?page=N` documents themselves, so callers can read the count from
/// any page they happened to fetch. Returns 1 when no page number is
/// found.
int parseUserProfileBooklistsPagesTotal(String html) {
  final doc = html_parser.parse(html);
  // The paginator lives inside the booklists tab; scope the query to
  // it so another tab's paginator (comments, plans) cannot count.
  final tab = doc.querySelector('div[z-tab="booklists"]');
  if (tab == null) return 1;
  final pag = tab.querySelector('.paginator_booklists');
  if (pag == null) return 1;
  var max = 1;
  for (final a in pag.querySelectorAll('a[href]')) {
    final match = RegExp(
      r'[?&]page=(\d+)',
    ).firstMatch(a.attributes['href'] ?? '');
    if (match == null) continue;
    final value = int.tryParse(match.group(1)!);
    if (value != null && value > max) max = value;
  }
  return max;
}

/// Recommended booklists from `POST /papi/booklist/get-from-category`:
/// the response's `html` array, one JSON object per list (`id`, `href`,
/// `title`, `author`, `authorProfile`, `quantity`, `views`, …).
/// Entries without a numeric id or a title are skipped. [baseUrl] is
/// the mirror origin, used to resolve relative hrefs.
List<Booklist> parseRecommendedBooklists(
  Object? html, {
  required String baseUrl,
}) {
  if (html is! List) return const [];
  final lists = <Booklist>[];
  for (final entry in html) {
    if (entry is! Map<String, dynamic>) continue;
    final id = entry['id']?.toString() ?? '';
    if (!RegExp(r'^\d+$').hasMatch(id)) continue;
    final name = entry['title']?.toString().trim() ?? '';
    if (name.isEmpty) continue;
    lists.add(
      Booklist(
        id: id,
        name: name,
        description: entry['description']?.toString() ?? '',
        author: entry['author']?.toString().trim() ?? '',
        authorProfile: entry['authorProfile']?.toString().trim() ?? '',
        count: entry['quantity'] is int
            ? entry['quantity'] as int
            : int.tryParse(entry['quantity']?.toString() ?? ''),
        views: entry['views']?.toString() ?? '',
        comments: entry['comments']?.toString() ?? '',
        color: entry['color'] is int
            ? entry['color'] as int
            : int.tryParse(entry['color']?.toString() ?? ''),
        url: Booklist._resolveUrl(entry['href']?.toString() ?? '', baseUrl),
      ),
    );
  }
  return lists;
}

/// Books on the FIRST page of a booklist detail page, from the
/// server-rendered `<z-bookcard>` elements (`.readlist-view`).
///
/// Page 1 is never served by the JSON endpoint (see
/// `getBooklistBooks` in the API layer) — it lives in the detail document.
/// Shape confirmed from the live `/booklist/4088695/62a0c2/001.html`
/// document 2026-11-07: each card carries the book in its attributes
/// (`id`, `href`, `publisher`, `language`, `year`, `extension`,
/// `filesize`, `rating`, `read`), the cover in a child `<img
/// data-src>`, and the title/author in `<div slot="title">` /
/// `<div slot="author">`. The book hash is the first segment of the
/// href (`/book/{hash}/{slug}.html`). The `user_token` attribute (a
/// JWT carrying the signed-in user's identity) is deliberately NOT
/// read. Cards marked `deleted="1"` are skipped. An empty list means
/// the page had no cards (or was not a detail page at all).
///
/// Detail-only fields: a card on the signed-in user's own list also
/// carries its readlist membership-row id in `booklistsindex` and the
/// per-book note in `<div slot="note">` (see `z-bookcard`); both are
/// parsed into [Book.readlistBookId] / [Book.note] when present, so
/// remove-book and save-description can use them without an extra
/// `current-user` round trip. Cards on other users' lists carry
/// neither.
List<Book> parseBooklistDetailBooks(String html, {String? baseUrl}) {
  final doc = html_parser.parse(html);
  final books = <Book>[];
  // Cards live in `.readlist-view`; scope the query to it so a card
  // elsewhere in the document cannot leak into the list. Fall back
  // to the whole document when the view is absent, so a page-shape
  // change does not silently return an empty list.
  final view = doc.querySelector('.readlist-view');
  final cards = view != null
      ? view.querySelectorAll('z-bookcard')
      : doc.querySelectorAll('z-bookcard');
  for (final card in cards) {
    final id = int.tryParse(card.attributes['id']?.trim() ?? '');
    if (id == null) continue;
    if (card.attributes['deleted']?.trim() == '1') continue;
    final href = card.attributes['href']?.trim() ?? '';
    final img = card.querySelector('img');
    final coverRaw = img?.attributes['data-src']?.trim() ??
        img?.attributes['src']?.trim() ??
        '';
    final title =
        card.querySelector('div[slot="title"]')?.text.trim() ?? '';
    final author =
        card.querySelector('div[slot="author"]')?.text.trim() ?? '';
    final note =
        card.querySelector('div[slot="note"]')?.text.trim() ?? '';
    books.add(
      Book(
        id: id,
        title: title,
        hash: _hashFromBookHref(href),
        author: author.isEmpty ? null : author,
        cover: coverRaw.isEmpty
            ? null
            : (baseUrl == null ? coverRaw : _resolveCardUrl(coverRaw, baseUrl)),
        publisher: _cardAttr(card, 'publisher'),
        year: int.tryParse(card.attributes['year']?.trim() ?? ''),
        language: _cardAttr(card, 'language'),
        extension: _cardAttr(card, 'extension'),
        filesizeString: _cardAttr(card, 'filesize'),
        interestScore: _cardAttr(card, 'rating'),
        readOnlineUrl: _cardAttr(card, 'read'),
        readlistBookId:
            int.tryParse(card.attributes['booklistsindex']?.trim() ?? ''),
        note: note.isEmpty ? null : note,
      ),
    );
  }
  return books;
}

String? _cardAttr(dom.Element el, String name) {
  final value = el.attributes[name]?.trim();
  return value == null || value.isEmpty ? null : value;
}

/// Book hash from a `/book/{hash}/{slug}.html` href, or null when the
/// href does not have that shape.
String? _hashFromBookHref(String href) {
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

/// Injectable Rust parse hooks (phase 3). The host app sets these to
/// flutter_rust_bridge-backed implementations returning the SAME
/// models; when null (default) the Dart implementations above are
/// used as the fallback. Behavior must be identical either way —
/// test/parsers/booklist_*.dart and user_profile_booklists_test.dart
/// are the contracts for both.
Future<BooklistsPage> Function(String html, String baseUrl)?
    booklistsPageParseOverride;
Future<List<Booklist>> Function(String html, String baseUrl)?
    userProfileBooklistsParseOverride;
Future<List<Book>> Function(String html, String? baseUrl)?
    booklistDetailBooksParseOverride;

/// Hook-aware entries: Rust bridge when injected, Dart fallback
/// otherwise. All call sites route through these (the Future wrapper
/// is behavior-neutral — every caller already runs in async contexts).
Future<BooklistsPage> parseBooklistsPageH(
  String html, {
  required String baseUrl,
}) async =>
    booklistsPageParseOverride != null
        ? await booklistsPageParseOverride!(html, baseUrl)
        : parseBooklistsPage(html, baseUrl: baseUrl);

Future<List<Booklist>> parseUserProfileBooklistsH(
  String html, {
  required String baseUrl,
}) async =>
    userProfileBooklistsParseOverride != null
        ? await userProfileBooklistsParseOverride!(html, baseUrl)
        : parseUserProfileBooklists(html, baseUrl: baseUrl);

Future<List<Book>> parseBooklistDetailBooksH(
  String html, {
  String? baseUrl,
}) async =>
    booklistDetailBooksParseOverride != null
        ? await booklistDetailBooksParseOverride!(html, baseUrl)
        : parseBooklistDetailBooks(html, baseUrl: baseUrl);
