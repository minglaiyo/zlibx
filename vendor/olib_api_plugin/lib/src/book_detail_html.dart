import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'book.dart';

/// Metadata parsed from a book detail page's HTML
/// (`GET /book/{hash}/{slug}.html`).
///
/// The eapi book object does not carry these fields — they only exist
/// as server-rendered rows in the detail page, one row per property:
/// a `div.bookProperty.property_<key>` holding a
/// `div.property_label` (text ends with `:` or `：`) and a
/// `div.property_value` (plain text, sometimes with inner spans —
/// the text is taken). Rows are matched by the `property_<key>`
/// class (locale-independent); when a row has no such class, the
/// label text is matched instead (labels are localized: zh `卷:` /
/// `ISBN 13:` / `ISBN 10:` / `IPFS:`, en `Volume:` / `ISBN 13:` /
/// `ISBN 10:` / `IPFS:`).
///
/// The IPFS row is special: its visible text is just `CID` /
/// `CID Blake2b` — the real values are the two spans' `data-copy`
/// attributes (first = CID, second = CID Blake2b).
///
/// The `property_volume` row was verified against a second capture
/// (the 阿兹卡班的囚徒 book, which has one): the same uniform
/// pattern, class `property_volume`, label `卷:`, plain-text value
/// (`第21章 赫敏的秘密`). The other rows in that capture confirm the
/// shape too: `property_categories` carries its value inside a link
/// (take the text), and `property_content_type` (`内容类型:` / `书籍`)
/// exists but is not parsed — it is skipped like any other row.
///
/// The rating is NOT a `bookProperty` row: it lives in the page
/// header block `div.book-rating-detail > div.book-rating`, two
/// spans around a slash — `span.book-rating-interest-score` (社区
/// 评分, 0–5) and `span.book-rating-quality-score` (质量分, 0–5).
/// Verified against the 超速学习 capture 2026-11-12 (zh.z-library.sk,
/// interest `3.0` / quality `5.0`). An unrated book keeps the spans
/// in the DOM but hides them with the extra class `none` (the page's
/// own JS re-fills the values and removes `none` after the user
/// rates) — a `none`-classed span parses to null so the app never
/// shows a stale/hidden value.
class BookDetailMetadata {
  final String? volume;
  final String? isbn10;
  final String? isbn13;
  final String? ipfsCid;
  final String? ipfsCidBlake2b;

  /// Community interest score as rendered (`3.0`), or null when the
  /// page hides the span (unrated) or it carries no text.
  final String? ratingInterest;

  /// Community quality score as rendered (`5.0`), same null rules.
  final String? ratingQuality;

  const BookDetailMetadata({
    this.volume,
    this.isbn10,
    this.isbn13,
    this.ipfsCid,
    this.ipfsCidBlake2b,
    this.ratingInterest,
    this.ratingQuality,
  });

  bool get isEmpty =>
      volume == null &&
      isbn10 == null &&
      isbn13 == null &&
      ipfsCid == null &&
      ipfsCidBlake2b == null &&
      ratingInterest == null &&
      ratingQuality == null;
}

/// Parse the detail-page metadata rows out of a detail page's HTML.
/// Missing rows parse to null; empty/whitespace-only values parse to
/// null. A page with no `bookProperty` rows parses to an all-null
/// [BookDetailMetadata] (never throws).
BookDetailMetadata parseBookDetailProperties(String html) {
  final doc = html_parser.parse(html);

  String? byClass(String key) {
    final row = doc.querySelector('div.bookProperty.property_$key');
    if (row == null) return null;
    return _rowValue(row);
  }

  String? byLabel(String label) {
    for (final row in doc.querySelectorAll('div.bookProperty')) {
      final labelEl = row.querySelector('div.property_label');
      if (labelEl == null) continue;
      if (_normalizeLabel(labelEl.text) != label) continue;
      return _rowValue(row);
    }
    return null;
  }

  // IPFS is read from `data-copy` attributes, not from the row text.
  List<String> ipfsCopies() {
    final row = doc.querySelector('div.bookProperty.property_ipfs_cid');
    final scope = row ?? _rowWithLabel(doc, 'ipfs');
    if (scope == null) return const [];
    return scope
        .querySelectorAll('span[data-copy]')
        .map((span) => span.attributes['data-copy']?.trim() ?? '')
        .where((value) => value.isNotEmpty)
        .toList();
  }

  // Rating spans: visible text only — the site hides an unrated span
  // with the extra class `none`, which must parse to null (see the
  // class doc).
  String? ratingScore(String selector) {
    final span = doc.querySelector(selector);
    if (span == null) return null;
    if (span.classes.contains('none')) return null;
    final text = span.text.trim();
    return text.isEmpty ? null : text;
  }

  final copies = ipfsCopies();
  return BookDetailMetadata(
    volume: byClass('volume') ?? byLabel('卷') ?? byLabel('volume'),
    isbn10: byClass('isbn_10') ?? byLabel('isbn 10'),
    isbn13: byClass('isbn_13') ?? byLabel('isbn 13'),
    ipfsCid: copies.isNotEmpty ? copies[0] : null,
    ipfsCidBlake2b: copies.length > 1 ? copies[1] : null,
    ratingInterest: ratingScore('.book-rating-interest-score'),
    ratingQuality: ratingScore('.book-rating-quality-score'),
  );
}

/// The row's `property_value` text, trimmed; null when the row has no
/// value element or its text is empty/whitespace-only.
String? _rowValue(dom.Element row) {
  final valueEl = row.querySelector('div.property_value');
  if (valueEl == null) return null;
  final text = valueEl.text.trim();
  return text.isEmpty ? null : text;
}

/// The `bookProperty` row whose label normalizes to [label], or null.
/// Rows without a label element (e.g. `property_language_year`,
/// which is a bare `chinese, 2019` text node) are skipped.
dom.Element? _rowWithLabel(dom.Document doc, String label) {
  for (final row in doc.querySelectorAll('div.bookProperty')) {
    final labelEl = row.querySelector('div.property_label');
    if (labelEl == null) continue;
    if (_normalizeLabel(labelEl.text) == label) return row;
  }
  return null;
}

/// A label with its trailing `:`/`：` stripped and lowercased, so
/// `ISBN 13:` and `isbn 13` compare equal.
String _normalizeLabel(String text) {
  var label = text.trim().toLowerCase();
  while (label.endsWith(':') || label.endsWith('：')) {
    label = label.substring(0, label.length - 1);
  }
  return label.trim();
}

/// Injectable Rust parse hook (phase 3). The host app sets this to a
/// flutter_rust_bridge-backed implementation returning the SAME
/// [BookDetailMetadata] model; when null (default) the Dart
/// implementation above is used as the fallback. Behavior must be
/// identical either way — test/parsers/book_detail_metadata_test.dart
/// is the contract for both.
Future<BookDetailMetadata> Function(String html)? bookDetailParseOverride;

/// The book a detail page describes, built from that page's own HTML.
///
/// This is the fallback for `GET /eapi/book/{id}/{hash}`, and it
/// exists because the two channels do not share an identifier: eapi
/// wants a 6-character hash while a webpage only ever carries the
/// 10-character short hash. Measured on the live site 2026-11-24 —
/// `/eapi/book/26610712/Ej8q7Dmrv9` answers `400 无效哈希` and the 6-char
/// hash of any book appears nowhere in that book's HTML — so a book
/// that reached the app through an HTML listing (search, booklist, a
/// shared link) has no eapi detail call to make. This parser is what
/// fills the detail screen for it.
///
/// Sources, in order of trust (all read from the capture
/// `/book/Ej8q7Dmrv9/三体.html`, 214 KB, 2026-11-24):
///  1. the `application/ld+json` block (`@type: Book`) — locale-free
///     structured data: `name`, `description`, `author[].name`,
///     `publisher.name`, `image`, `isbn`, `numberOfPages`,
///     `datePublished`, `inLanguage`;
///  2. the rendered DOM (`h1.book-title`, `i.authors`,
///     `#bookDescriptionBox`, the `bookProperty` rows) for whatever
///     the JSON-LD omits or double-encodes;
///  3. [parseBookDetailProperties] for the rows the JSON-LD cannot
///     express (both ISBNs separately, volume, IPFS, the two rating
///     spans).
///
/// Two orderings matter, and both come from the page being a
/// machine-readable template rather than prose:
///  * `language` prefers the JSON-LD (`chinese`) over the DOM row
///    (`中文`), because the app compares language against the filter
///    values the search cards use (`z-bookcard language="chinese"`).
///  * `author` prefers the DOM over the JSON-LD, because this site
///    renders the structured-data author name with literal braces
///    (`"name":"{刘慈欣}"`) — a templating artifact, not data.
///
/// [Book.href] and [Book.hash] come from the [href] the caller
/// fetched, never from a link scraped out of the page: a detail page
/// links to other books (recommendations), so a scraped `/book/…`
/// could describe a different one.
///
/// Returns null when the page is not a book page (no `data-book_id`,
/// no title) so the caller keeps its own error instead of painting an
/// empty detail screen. Nothing here throws — a missing row is a null
/// field.
Book? parseBookDetailPage(String html, {String? baseUrl, String? href}) {
  final doc = html_parser.parse(html);
  // Every `data-book_id` on a detail page is the page's own book (the
  // capture repeats the same value 5 times across the buttons); a
  // recommendation never carries one.
  final idText = doc
      .querySelectorAll('[data-book_id]')
      .map((el) => (el.attributes['data-book_id'] ?? '').trim())
      .firstWhere((value) => value.isNotEmpty, orElse: () => '');
  final id = int.tryParse(idText);
  if (id == null) return null;

  final ld = _bookLdJson(doc);
  final metadata = parseBookDetailProperties(html);
  final cleanHref = _stripQuery(href ?? '');

  final title =
      _inlineText(doc.querySelector('h1.book-title')) ??
      _ldString(ld?['name'], stripBraces: true) ??
      '';
  if (title.isEmpty) return null;

  // `EPUB, 2.48 MB` — one row, two fields. A page whose file row is
  // absent (or reshaped) leaves both null; the download button's own
  // label (`epub, 2.48 MB`) is the fallback the capture also offers.
  final fileRow = _propertyValue(doc, 'file') ?? _dlLabel(doc, '$id');
  String? extension;
  String? filesizeString;
  if (fileRow != null) {
    final split = fileRow.lastIndexOf(',');
    if (split > 0) {
      extension = _nullable(fileRow.substring(0, split).trim().toLowerCase());
      filesizeString = _nullable(fileRow.substring(split + 1).trim());
    } else {
      filesizeString = _nullable(fileRow);
    }
  }

  final isbn = _ldString(ld?['isbn'], stripBraces: true);
  final pages = _intOrNull(_ldString(ld?['numberOfPages']));
  final description =
      _descriptionText(doc) ?? _plainText(_ldString(ld?['description']));

  return Book(
    id: id,
    title: title,
    hash: Book.hashFromBookHref(cleanHref),
    href: cleanHref.isEmpty ? null : cleanHref,
    author:
        _inlineText(doc.querySelector('i.authors')) ??
        _ldAuthors(ld?['author']),
    publisher: _propertyValue(doc, 'publisher') ?? _ldName(ld?['publisher']),
    year:
        _intOrNull(_digitRun(_propertyValue(doc, 'year'))) ??
        _intOrNull(_digitRun(_ldString(ld?['datePublished']))),
    language: _ldLanguage(ld?['inLanguage']) ?? _propertyValue(doc, 'language'),
    categories: _propertyValue(doc, 'categories'),
    // `numberOfPages: 0` is the site's "unknown", not a page count.
    pages: (pages == null || pages == 0) ? null : pages,
    extension: extension,
    filesizeString: filesizeString,
    description: description,
    cover: _coverOf(doc, ld, baseUrl),
    isbn10:
        metadata.isbn10 ?? (isbn != null && isbn.length == 10 ? isbn : null),
    isbn13:
        metadata.isbn13 ?? (isbn != null && isbn.length == 13 ? isbn : null),
    volume: metadata.volume,
    ipfsCid: metadata.ipfsCid,
    ipfsCidBlake2b: metadata.ipfsCidBlake2b,
    ratingInterest: metadata.ratingInterest,
    ratingQuality: metadata.ratingQuality,
    downloadPath: _dlLinkOf(doc, baseUrl, bookId: '$id'),
  );
}

/// The books the detail page recommends below the book — the site's
/// own 相似书籍 block, and the fallback for
/// `GET /eapi/book/{id}/{hash}/similar` when there is no eapi hash.
///
/// Shape, from the same 2026-11-24 capture:
///
///     <div class="books-mosaic">
///       <div class="recommendations"><h2>您可能感兴趣</h2></div>
///       <z-masonry source="recommend" columns="5" batch="21">
///         <a href="/book/0vpJZoQLRr/精排十日终焉.html?dsource=recommend">
///           <z-cover volume id="102668369" isbn="" author="杀手佣兵团"
///                    title="…"><img src="https://…jpg" loading="lazy">
///           </z-cover>
///         </a>
///       </z-masonry>
///     </div>
///
/// A recommendation is a `z-cover` (id / author / title / isbn)
/// wrapped in a `/book/{shortHash}/{slug}.html` link — NOT a
/// `z-bookcard`. It carries no year, extension, size or rating, so
/// those stay null and the similar-books screen shows what the site
/// shows. The `?dsource=recommend` tracking marker is dropped from
/// [Book.href]. The site's placeholder cover
/// (`/img/cover-not-exists.png`, 18 occurrences in the capture)
/// parses to null, which is what the cover widget reads as "no
/// cover". An absent block returns an empty list.
List<Book> parseBookDetailRecommendations(String html, {String? baseUrl}) {
  final doc = html_parser.parse(html);
  final scope =
      doc.querySelector('z-masonry[source="recommend"]') ??
      doc.querySelector('.books-mosaic');
  if (scope == null) return const [];
  final books = <Book>[];
  for (final anchor in scope.querySelectorAll('a[href^="/book/"]')) {
    final cover = anchor.querySelector('z-cover');
    if (cover == null) continue;
    final id = int.tryParse((cover.attributes['id'] ?? '').trim());
    final title = _nullable((cover.attributes['title'] ?? '').trim());
    if (id == null || title == null) continue;
    final cleanHref = _stripQuery((anchor.attributes['href'] ?? '').trim());
    final isbn = _nullable((cover.attributes['isbn'] ?? '').trim());
    books.add(
      Book(
        id: id,
        title: title,
        author: _nullable((cover.attributes['author'] ?? '').trim()),
        hash: Book.hashFromBookHref(cleanHref),
        href: cleanHref.isEmpty ? null : cleanHref,
        cover: _coverUrlOrNull(_imgSrc(cover), baseUrl),
        isbn13: isbn != null && isbn.length == 13 ? isbn : null,
        isbn10: isbn != null && isbn.length == 10 ? isbn : null,
      ),
    );
  }
  return books;
}

/// The page's `application/ld+json` object when one describes a Book,
/// else null. A book page carries three blocks (`WebSite`, `Book`,
/// `BreadcrumbList`), so the `@type` test is required, not optional.
/// Malformed JSON is skipped rather than thrown.
Map<String, dynamic>? _bookLdJson(dom.Document doc) {
  for (final script in doc.querySelectorAll(
    'script[type="application/ld+json"]',
  )) {
    final text = script.text.trim();
    if (text.isEmpty) continue;
    try {
      final decoded = jsonDecode(text);
      for (final item in decoded is List ? decoded : [decoded]) {
        if (item is Map && item['@type'] == 'Book') {
          return item.cast<String, dynamic>();
        }
      }
    } on FormatException {
      continue;
    }
  }
  return null;
}

/// A JSON-LD scalar as text. [stripBraces] drops the literal `{…}`
/// wrapper this site puts around template-filled values.
String? _ldString(Object? value, {bool stripBraces = false}) {
  if (value == null) return null;
  var text = value.toString().trim();
  if (stripBraces &&
      text.length > 1 &&
      text.startsWith('{') &&
      text.endsWith('}')) {
    text = text.substring(1, text.length - 1).trim();
  }
  return text.isEmpty ? null : text;
}

/// The JSON-LD author list rendered the way the DOM renders it:
/// several names joined with `, `. An item is either
/// `{"@type":"Person","name":…}` or a bare string.
String? _ldAuthors(Object? value) {
  if (value is! List) return _ldString(value, stripBraces: true);
  final names = <String>[];
  for (final item in value) {
    final name = item is Map
        ? _ldString(item['name'], stripBraces: true)
        : _ldString(item, stripBraces: true);
    if (name != null) names.add(name);
  }
  return names.isEmpty ? null : names.join(', ');
}

/// A JSON-LD `{…}` object holding a `name`, or a bare scalar.
String? _ldName(Object? value) => value is Map
    ? _ldString(value['name'], stripBraces: true)
    : _ldString(value, stripBraces: true);

/// `inLanguage` is `{"@type":"Language","name":"chinese"}` or a bare
/// string; either way the machine value is what the app stores.
String? _ldLanguage(Object? value) => _ldName(value);

/// A `bookProperty` row's value text by its `property_<key>` class.
/// The value element is a `div` for most rows but a `span` for
/// `property_language`, so the lookup is by class, not by tag.
String? _propertyValue(dom.Document doc, String key) {
  final row = doc.querySelector('div.bookProperty.property_$key');
  final value = row?.querySelector('.property_value')?.text.trim();
  return _nullable(value ?? '');
}

/// The download button's label text (`pdf, 12.35 MB`), for pages with no
/// file row. Taken from the same element [_dlLinkOf] reads, so a page
/// never reports one button's size with another button's address.
String? _dlLabel(dom.Document doc, [String? bookId]) =>
    _inlineText(_dlButton(doc, bookId: bookId));

/// Whether this node is a clone the client is meant to move, not a button
/// the user can tap.
bool _isHiddenClone(dom.Element a) {
  if (a.attributes.containsKey('hidden')) return true;
  final style = a.attributes['style'] ?? '';
  if (style.contains('display: none') || style.contains('display:none')) {
    return true;
  }
  dom.Node? parent = a.parentNode;
  while (parent != null) {
    if (parent is dom.Element && parent.localName == 'template') return true;
    parent = parent.parentNode;
  }
  return false;
}

/// 按钮 href 里 `/dl/{token}` 那一段（含 query），取不到就返回 null。
///
/// 2026-11-24 那份真页面抓包把这个形状钉死了：href 写的是**站内绝对
/// 地址** `https://zh.z-library.sk/dl/EwAD8KXkBL`，不是相对路径。此前
/// 这一支只认 `startsWith('/dl/')`，于是每个真页面的按钮都被丢掉、
/// 每一本都报成"页面上没有下载地址"。相对路径仍然接受，但绝对地址必须
/// 是 https——只有 origin+path 会被保留，好让 token 落在当前镜像自己的
/// host 上（墙 cookie 是按 host 生效的）。
String? _dlPathOfHref(String raw) {
  if (raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null) return null;
  if (uri.hasScheme) {
    if (uri.scheme != 'https' || !uri.path.startsWith('/dl/')) return null;
    return uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
  }
  if (!raw.startsWith('/dl/')) return null;
  return raw;
}

/// 页面上看得见的下载锚点，按可信度排好序（重复的只留一次）。
///
/// [bookId] 非空时，`data-book_id` 指向别处的锚点一律不算——浏览器读回来
/// 的可能是首页，上面那些按钮带着**别本书**的 token，抓错一本比抓不到更
/// 糟。
List<dom.Element> _visibleDlAnchors(dom.Document doc, {String? bookId}) {
  final ordered = <dom.Element>[
    ...doc.querySelectorAll('a.dlButton.addDownloadedBook'),
    ...doc.querySelectorAll('a.dlButton'),
    ...doc.querySelectorAll('a[href*="/dl/"]'),
  ];
  final wanted = bookId?.trim() ?? '';
  final seen = <dom.Element>{};
  return ordered.where((a) {
    if (!seen.add(a) || _isHiddenClone(a)) return false;
    final owner = (a.attributes['data-book_id'] ?? '').trim();
    return wanted.isEmpty || owner.isEmpty || owner == wanted;
  }).toList();
}

/// The button the user actually taps: the first visible anchor whose href
/// really carries a `/dl/` token. The reader button is `a.dlButton` too
/// (`btn btn-primary dlButton reader-link`) but its href is a
/// `reader.z-library.sk/read/…` URL, so it is skipped here rather than
/// mistaken for the download address.
dom.Element? _dlButton(dom.Document doc, {String? bookId}) {
  for (final a in _visibleDlAnchors(doc, bookId: bookId)) {
    if (_dlPathOfHref((a.attributes['href'] ?? '').trim()) != null) return a;
  }
  return null;
}

/// The site's own download address (`/dl/{token}`) off the visible
/// download button, rebuilt on [baseUrl]'s origin. Hidden and
/// `<template>` clones are not read — the button is the address the
/// user's tap follows.
String? _dlLinkOf(dom.Document doc, String? baseUrl, {String? bookId}) {
  final a = _dlButton(doc, bookId: bookId);
  if (a == null) return null;
  final path = _dlPathOfHref((a.attributes['href'] ?? '').trim());
  if (path == null) return null;
  return baseUrl == null ? path : '$baseUrl$path';
}

/// 一页**已经拿到手**的书页 HTML 里那个可见下载按钮的绝对地址。
///
/// 下载那条腿用它：书页站在墙后时，App 用真浏览器把 HTML 读回来，插件
/// 只负责从里面取 `/dl/{token}`——不再要求"解完墙 → cookie 回灌 Dio →
/// 重发一遍"那条链成立（那条链的成败取决于墙 cookie 的**名字**在不在
/// 白名单里，而这个名字在设备外永远看不到）。
/// [pageUrl] 是那一页自己的地址，用来把 `/dl/…` 补成站内绝对 URL；
/// 补不出来（不是 http(s) 地址）就当没找到，绝不交出一个相对路径。
/// [bookId] 用来拒绝属于别本书的按钮（浏览器读回来的可能是首页）。
String? dlLinkFromPageHtml(String html, String pageUrl, {String? bookId}) {
  final origin = Uri.tryParse(pageUrl)?.origin ?? '';
  if (!origin.startsWith('https://')) return null;
  return _dlLinkOf(html_parser.parse(html), origin, bookId: bookId);
}

/// The book's own cover. The JSON-LD `image` is unambiguous; as a
/// fallback the first `/covers`-hosted image in the document is the
/// book's own, because the recommendations render after it.
String? _coverOf(dom.Document doc, Map<String, dynamic>? ld, String? baseUrl) {
  final fromLd = _coverUrlOrNull(
    _ldString(ld?['image'], stripBraces: true) ?? '',
    baseUrl,
  );
  if (fromLd != null) return fromLd;
  // No usable image in the structured data (absent, or the site's own
  // `cover-not-exists` placeholder): the book's cover is the first
  // cover-hosted image in the document, because the recommendations
  // render below it.
  for (final img in doc.querySelectorAll('img[src], img[data-src]')) {
    final raw = _imgSrc(img);
    if (raw.contains('/covers')) return _coverUrlOrNull(raw, baseUrl);
  }
  return null;
}

/// A cover URL, or null for the site's "no cover" placeholder.
String? _coverUrlOrNull(String raw, String? baseUrl) {
  if (raw.isEmpty || raw.contains('cover-not-exists')) return null;
  if (baseUrl == null) return raw;
  if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
  if (raw.startsWith('//')) return 'https:$raw';
  if (raw.startsWith('/')) return '$baseUrl$raw';
  return raw;
}

/// `data-src` when the image is lazy-loaded, else `src`.
String _imgSrc(dom.Element scope) {
  final img = scope.localName == 'img' ? scope : scope.querySelector('img');
  if (img == null) return '';
  return (img.attributes['data-src'] ?? img.attributes['src'] ?? '').trim();
}

/// The description with its paragraph structure kept: the box is
/// `<p>`-segmented reader text, and flattening it into one line (what
/// `.text` does) loses the paragraphs the user wrote.
String? _descriptionText(dom.Document doc) {
  final box = doc.querySelector('#bookDescriptionBox');
  if (box == null) return null;
  final text = html_parser.parseFragment(_blockBreaks(box.innerHtml)).text ??
      '';
  final lines = text
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
  return lines.isEmpty ? null : lines;
}

/// Whitespace-collapsed single-line text, or null when empty.
String? _inlineText(dom.Element? el) {
  final text = el?.text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return _nullable(text ?? '');
}

/// Text that arrived with markup still in it (the JSON-LD description
/// carries `&lt;p&gt;`), reduced to plain paragraphs.
String? _plainText(String? value) {
  if (value == null) return null;
  // The JSON-LD description escapes its own markup (`&lt;p&gt;`), so
  // the escapes are released first and only then does paragraph markup
  // become a line break. Parsing the result as a fragment is what
  // decodes the remaining entities and drops the tags.
  final released = value
      .replaceAll('&lt;p&gt;', '<p>')
      .replaceAll('&lt;/p&gt;', '</p>')
      .replaceAll('&lt;br&gt;', '<br>')
      .replaceAll('&amp;nbsp;', ' ');
  final joined = (html_parser.parseFragment(_blockBreaks(released)).text ?? '')
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
  return joined.isEmpty ? null : joined;
}

/// Block markup turned into line breaks before a description is
/// flattened to text. Both the open and the close tag break: the site
/// writes reader paragraphs as `text<p>next</p><p>more</p>`, so
/// treating only the closing tag as a boundary runs the first two
/// paragraphs into one line (measured on the 三体 description box,
/// where 我个人… followed 顺手传上来了。 with no break).
String _blockBreaks(String html) => html.replaceAll(
  RegExp(r'</?(?:p|br)\b[^>]*/?>', caseSensitive: false),
  '\n',
);

String? _nullable(String value) => value.isEmpty ? null : value;

/// The first run of digits in a value, so a `datePublished` of
/// `2008-11-01` or a year row of `2008.` both yield `2008`.
String? _digitRun(String? value) {
  if (value == null) return null;
  return RegExp(r'\d{4}').firstMatch(value)?.group(0);
}

int? _intOrNull(String? value) => value == null ? null : int.tryParse(value);

/// A path without its query — the site appends `?dsource=recommend`
/// and similar markers to book links, and the app should never re-
/// fetch or cache a tracking URL as a book's canonical href.
String _stripQuery(String href) =>
    href.contains('?') ? href.substring(0, href.indexOf('?')) : href;
