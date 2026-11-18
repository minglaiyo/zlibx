import 'package:html/parser.dart' as html_parser;

import 'book_detail_html.dart';

/// Everything one book detail page carries beyond the eapi book
/// object, parsed from a single `GET /book/{hash}/{slug}.html` fetch:
/// the server-rendered metadata rows. `fetchBookDetailExtras` (in the
/// search mixin) returns this.
class BookDetailExtras {
  /// The `bookProperty` rows (volume / ISBN / IPFS / rating — see
  /// [parseBookDetailProperties]). May be all-null when the page has
  /// no property box.
  final BookDetailMetadata metadata;

  /// 详情页 HTML 上的关键词（`/terms/<词>` 链接文本，去重、页内顺序、
  /// 最多 12 个）。eapi 不携带；HTML 抓取被跳过/失败时为空列表。
  final List<String> keywords;

  const BookDetailExtras({required this.metadata, this.keywords = const []});
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
