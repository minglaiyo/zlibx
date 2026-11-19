import 'package:html/parser.dart' as html_parser;

import 'book_detail_html.dart';
import 'booklist.dart';

/// Everything one book detail page carries beyond the eapi book
/// object, parsed from a single `GET /book/{hash}/{slug}.html` fetch:
/// the server-rendered metadata rows plus the related-booklists
/// block. `fetchBookDetailExtras` (in the search mixin) returns this,
/// so the detail page costs ONE HTML fetch for both.
class BookDetailExtras {
  /// The `bookProperty` rows (volume / ISBN / IPFS / rating — see
  /// [parseBookDetailProperties]). May be all-null when the page has
  /// no property box.
  final BookDetailMetadata metadata;

  /// 详情页 HTML 上的关键词（`/terms/<词>` 链接文本，去重、页内顺序、
  /// 最多 12 个）。eapi 不携带；HTML 抓取被跳过/失败时为空列表。
  final List<String> keywords;

  /// 详情页底部"关联书单"区块（[parseRelatedBooklists]）。eapi 不
  /// 携带；大多数书没有该区块，抓取被跳过/失败时同样是空列表。
  final List<Booklist> relatedBooklists;

  const BookDetailExtras({
    required this.metadata,
    this.keywords = const [],
    this.relatedBooklists = const [],
  });
}

/// Extract the keyword chips (the `/terms/<词>` links) from a book
/// detail page. Dart-only (site-verified 2026-11-19: the chips render
/// as plain anchor links, no Rust twin needed — the Rust detail hook
/// covers the metadata rows only). Deduped in page order, capped at
/// 12, texts longer than 30 chars are skipped (nav noise guard).
List<String> parseBookDetailKeywords(String html) {
  final doc = html_parser.parse(html);
  final seen = <String>{};
  final result = <String>[];
  for (final a in doc.querySelectorAll('a[href]')) {
    final href = a.attributes['href'] ?? '';
    if (!href.startsWith('/terms/') || href == '/terms/') continue;
    final text = a.text.trim();
    if (text.isEmpty || text.length > 30) continue;
    if (seen.add(text)) result.add(text);
    if (result.length >= 12) break;
  }
  return result;
}

/// The related booklists of one book detail page, from the
/// server-rendered `div.related-booklists-block` section (the site's
/// "关联书单" row). Dart-only, same as [parseBookDetailKeywords]: the
/// Rust detail hook covers the metadata rows only.
///
/// Shape confirmed from the live capture 2026-11-12 (Firefox,
/// zh.z-library.sk, the 超速学习 book page): the block holds a
/// `div.z-booklists-carousel` (attributes `data-book_id` /
/// `data-loader="loadBooklists"` / `data-booklists_type="related"`)
/// whose `<z-booklist>` cards are ALREADY RENDERED — the loader
/// attributes drive the site's lazy top-up for scrolling, not the
/// initial content, so the cards parse straight from the page and no
/// AJAX endpoint is needed. Each card:
///
///     <z-booklist tile="" href="/booklist/498889/f77552/1.html"
///                id="498889" topic="1" quantity="32">
///       <z-cover id="5748099" author="…" title="…" priority="true">
///         <img data-src="https://…jpg"></z-cover>
///       <z-cover …>…</z-cover>   ← the list's books, stacked
///     </z-booklist>
///
/// Reuses [Booklist.fromElement] (same card shape as the /booklists
/// pages). `topic` is the list's display name and may be a bare
/// number; the card carries no author/views/color attributes — those
/// fields stay empty. The per-book hash is NOT on these covers (the
/// related block wraps them in no `/book/…` link), so
/// [Booklist.previewBooks] parse with `hash` null — display-only
/// previews; the detail screen re-fetches them when opened. A page
/// with no block, a wall answer, or a malformed document yields an
/// empty list — this never throws on a missing section.
List<Booklist> parseRelatedBooklists(String html, {required String baseUrl}) {
  final doc = html_parser.parse(html);
  final block = doc.querySelector('.related-booklists-block');
  if (block == null) return const [];
  return block
      .querySelectorAll('z-booklist')
      .map((el) => Booklist.fromElement(el, baseUrl: baseUrl))
      .whereType<Booklist>()
      .toList();
}
