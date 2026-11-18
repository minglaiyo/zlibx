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

/// Injectable Rust parse hook (phase 3). See booklist.dart's hooks
/// for the contract; test/parsers/category_*.dart are the baselines.
Future<CategoryPage> Function(String html, String? baseUrl)?
    categoryPageParseOverride;

/// Hook-aware entry. Mirrors parseBooklistsPageH.
Future<CategoryPage> parseCategoryBooksPageH(
  String html, {
  String? baseUrl,
}) async =>
    categoryPageParseOverride != null
        ? await categoryPageParseOverride!(html, baseUrl)
        : parseCategoryBooksPage(html, baseUrl: baseUrl);

/// 分类目录树的一个链接节点（父级没有 slug，子级带 slug 和书量计数）。
class CategoryDirectoryLink {
  final int id;

  /// 子级的 slug（`/category/{id}/{slug}`）；父级为 null。
  final String? slug;
  final String name;

  /// 子级链接文本里带的藏书计数（"(23282)"）；解析不出为 null。
  final int? count;

  const CategoryDirectoryLink({
    required this.id,
    this.slug,
    required this.name,
    this.count,
  });
}

/// 分类目录树的一个分组：顶级分类 + 它的子分类。
class CategoryDirectoryGroup {
  final CategoryDirectoryLink parent;
  final List<CategoryDirectoryLink> children;

  const CategoryDirectoryGroup({required this.parent, required this.children});
}

/// `/categories` 目录页的解析结果。
class CategoriesDirectoryPage {
  final List<CategoryDirectoryGroup> groups;

  const CategoriesDirectoryPage({required this.groups});
}

/// Parse the `/categories` directory document into its tree.
///
/// Shape confirmed from the live page 2026-11-19 (zh.z-library.sk,
/// 841 category links): top-level categories link as bare
/// `/category/{id}` and appear immediately before their children,
/// which link as `/category/{id}/{slug}` with a "(count)" suffix in
/// the text. Document order therefore encodes the tree: a bare link
/// starts a new group, a slugged link joins the most recent group.
/// Links before any bare link (nav breadcrumbs) and non-category
/// links are skipped.
CategoriesDirectoryPage parseCategoriesDirectory(String html) {
  final doc = html_parser.parse(html);
  final groups = <CategoryDirectoryGroup>[];
  CategoryDirectoryGroup? current;
  final linkPattern = RegExp(r'^/category/(\d+)(?:/([^/?#]+))?[/?#]?$');
  for (final a in doc.querySelectorAll("a[href]")) {
    final match = linkPattern.firstMatch(a.attributes['href'] ?? '');
    if (match == null) continue;
    final id = int.tryParse(match.group(1)!);
    if (id == null) continue;
    final text = a.text.trim();
    if (text.isEmpty) continue;
    var name = text;
    int? count;
    final countMatch = RegExp(r'\((\d+)\)\s*$').firstMatch(text);
    if (countMatch != null) {
      count = int.tryParse(countMatch.group(1)!);
      name = text.substring(0, countMatch.start).trim();
    }
    if (name.isEmpty) continue;
    final slug = match.group(2);
    if (slug == null || slug.isEmpty) {
      // 父级。同一父链接在页内可能重复出现（吸顶导航等）：同 id 已是
      // 当前组时跳过，不重复开组。
      if (current != null && current.parent.id == id) continue;
      current = CategoryDirectoryGroup(
        parent: CategoryDirectoryLink(id: id, name: name, count: count),
        children: [],
      );
      groups.add(current);
    } else {
      // 子级挂最近的父级组；父级未出现（导航杂项）时丢弃。
      if (current == null) continue;
      current.children.add(
        CategoryDirectoryLink(id: id, slug: slug, name: name, count: count),
      );
    }
  }
  return CategoriesDirectoryPage(groups: groups);
}

/// Injectable Rust parse hook（同 categoryPageParseOverride 的契约）；
/// Dart 实现是默认回退。
Future<CategoriesDirectoryPage> Function(String html)?
categoriesDirectoryParseOverride;

/// Hook-aware entry. Mirrors parseCategoryBooksPageH.
Future<CategoriesDirectoryPage> parseCategoriesDirectoryH(String html) async =>
    categoriesDirectoryParseOverride != null
        ? await categoriesDirectoryParseOverride!(html)
        : parseCategoriesDirectory(html);
