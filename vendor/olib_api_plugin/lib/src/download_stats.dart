import 'package:html/parser.dart' as html_parser;

import 'book.dart';

/// The site's own "download history" (`下载历史`, `/users/downloads`),
/// parsed from the server-rendered document.
///
/// This is the ACCOUNT-WIDE per-download log the website shows — every
/// download event on every device / client (app, browser), newest
/// first, 50 rows per page, paginated with `?page=N`. The page's own JS
/// (dstats_*.js) does no AJAX: the table is all there is.
///
/// Shape confirmed from a live capture 2026-11-12 (zh.z-library.sk
/// saved `下载历史` page, 50 `tr.dstats-row` rows on page 1). Each row:
///
/// ```html
/// <tr class="dstats-row" data-item_id="23787383">
///   <td class="lg-w-60 hidden-xs">1</td>
///   <td class="lg-w-120">
///     <span class="hidden-xs">11.11.2026</span>
///     <span class="visible-xs">11.11.26</span>
///     <p>21:02</p>
///   </td>
///   <td class="lg-w-530">
///     <div class="book-title">
///       <a href="…/book/{shortHash}/{slug}.html">TITLE</a>
///     </div>
///   </td>
///   <td class="col-buttons"> …per-book rating widgets… </td>
/// </tr>
/// ```
///
/// `data-item_id` is the BOOK's numeric id (the per-row rating widgets
/// post against it — same widget as the book detail page), the link
/// carries the webpage short hash (the same one booklist / profile
/// books carry, resolved through `getBookInfo`'s `Invalid hash`
/// fallback), and the date cell holds the download stamp in the site's
/// `dd.mm.yyyy` + `HH:MM` rendering. The rows carry NO author, cover,
/// extension or size — callers that want those overlay them from the
/// eapi downloaded list (see the app's DownloadedBooksNotifier).
///
/// Skipped: a row without a parsable `data-item_id` or an empty title
/// (layout guards / broken records would otherwise render as dead
/// entries). The two-digit-year span (`11.11.26`) is deliberately not
/// read — the four-digit span is always present next to it.
List<Book> parseDownloadStatsPage(String html) {
  final doc = html_parser.parse(html);
  final books = <Book>[];
  for (final row in doc.querySelectorAll('tr.dstats-row')) {
    final id = int.tryParse(row.attributes['data-item_id']?.trim() ?? '');
    if (id == null || id <= 0) continue;
    final link = row.querySelector('.book-title a');
    final title = link?.text.trim() ?? '';
    if (title.isEmpty) continue;
    final href = link?.attributes['href']?.trim() ?? '';
    // Date/time: matched by content, not by the responsive-visibility
    // classes — the site reshuffles those between layouts, the text
    // formats are what stay stable.
    String? dateText;
    for (final span in row.querySelectorAll('span')) {
      final text = span.text.trim();
      if (RegExp(r'^\d{1,2}\.\d{1,2}\.\d{4}$').hasMatch(text)) {
        dateText = text;
        break;
      }
    }
    String? timeText;
    for (final p in row.querySelectorAll('p')) {
      final text = p.text.trim();
      if (RegExp(r'^\d{1,2}:\d{2}$').hasMatch(text)) {
        timeText = text;
        break;
      }
    }
    books.add(Book(
      id: id,
      title: title,
      href: href.isEmpty ? null : href,
      // 短 hash：与书单/个人页的书相同形态，详情页经 getBookInfo 的
      // `Invalid hash` 回退解析成真 eapi hash。
      hash: Book.hashFromBookHref(href),
      downloadedAt: _parseDstatsStamp(dateText, timeText),
    ));
  }
  return books;
}

/// `dd.mm.yyyy` + `HH:MM` as the site renders it, back into a
/// DateTime. Null unless BOTH parts parse — a date-only stamp would
/// display as a fabricated midnight, so a record with a missing /
/// unparsable time lists without a time line instead. The clock is
/// whatever the site rendered (no timezone is carried); the screen
/// formats it back verbatim, so parse → display never shifts a record.
DateTime? _parseDstatsStamp(String? dateText, String? timeText) {
  if (dateText == null || timeText == null) return null;
  final d = RegExp(r'(\d{1,2})\.(\d{1,2})\.(\d{4})').firstMatch(dateText);
  final t = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(timeText);
  if (d == null || t == null) return null;
  return DateTime(
    int.parse(d.group(3)!),
    int.parse(d.group(2)!),
    int.parse(d.group(1)!),
    int.parse(t.group(1)!),
    int.parse(t.group(2)!),
  );
}
