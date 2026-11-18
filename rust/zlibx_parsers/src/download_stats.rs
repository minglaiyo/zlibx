//! Download history parser — Rust port of
//! `vendor/olib_api_plugin/lib/src/download_stats.dart`.
//!
//! The site's own per-download log (`/users/downloads`): each
//! `tr.dstats-row` carries the book id in `data-item_id`, the short
//! hash in the `.book-title a` href, and the stamp as `dd.mm.yyyy` +
//! `HH:MM` text (matched by content, not by responsive-visibility
//! classes). `downloaded_at` is returned as an ISO-8601 local string
//! (`YYYY-MM-DDTHH:MM:00`) — the Rust Book model carries it as
//! Option<String> and the Dart mapping layer converts it back to a
//! DateTime with identical wall-clock values.

use scraper::{ElementRef, Selector};

use crate::fulltext::hash_from_href;
use crate::models::Book;

/// Parse the download history page. Rows without a parsable
/// `data-item_id` or an empty title are skipped; a missing/unparsable
/// time lists without a time line (None), never a fabricated midnight.
///
/// Mirrors `parseDownloadStatsPage(String html)`.
pub(crate) fn parse_download_stats_page(html: &str) -> Vec<Book> {
    let doc = scraper::Html::parse_document(html);
    let row_sel = Selector::parse("tr.dstats-row").unwrap();
    let link_sel = Selector::parse(".book-title a").unwrap();
    let span_sel = Selector::parse("span").unwrap();
    let p_sel = Selector::parse("p").unwrap();

    static DATE_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let date_re = DATE_RE.get_or_init(|| regex::Regex::new(r"^\d{1,2}\.\d{1,2}\.\d{4}$").unwrap());
    static TIME_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let time_re = TIME_RE.get_or_init(|| regex::Regex::new(r"^\d{1,2}:\d{2}$").unwrap());
    static DATE_PARTS: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let date_parts = DATE_PARTS.get_or_init(|| regex::Regex::new(r"(\d{1,2})\.(\d{1,2})\.(\d{4})").unwrap());
    static TIME_PARTS: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let time_parts = TIME_PARTS.get_or_init(|| regex::Regex::new(r"(\d{1,2}):(\d{2})").unwrap());

    let mut books = Vec::new();
    for row in doc.select(&row_sel) {
        let id: i64 = match row.attr("data-item_id").unwrap_or("").trim().parse() {
            Ok(v) if v > 0 => v,
            _ => continue,
        };
        let link: ElementRef = match row.select(&link_sel).next() {
            Some(l) => l,
            None => continue,
        };
        let title = link.text().collect::<String>().trim().to_string();
        if title.is_empty() {
            continue;
        }
        let href = link.attr("href").unwrap_or("").trim().to_string();

        // Date/time matched by content, not by the visibility classes.
        let mut date_text: Option<String> = None;
        for span in row.select(&span_sel) {
            let text = span.text().collect::<String>().trim().to_string();
            if date_re.is_match(&text) {
                date_text = Some(text);
                break;
            }
        }
        let mut time_text: Option<String> = None;
        for p in row.select(&p_sel) {
            let text = p.text().collect::<String>().trim().to_string();
            if time_re.is_match(&text) {
                time_text = Some(text);
                break;
            }
        }

        let downloaded_at = match (&date_text, &time_text) {
            (Some(d), Some(t)) => {
                let dm = date_parts.captures(d);
                let tm = time_parts.captures(t);
                match (dm, tm) {
                    (Some(d), Some(t)) => {
                        // dd.mm.yyyy + HH:MM → ISO-8601 local string.
                        let year: i64 = d.get(3).unwrap().as_str().parse().unwrap_or(0);
                        let month: i64 = d.get(2).unwrap().as_str().parse().unwrap_or(0);
                        let day: i64 = d.get(1).unwrap().as_str().parse().unwrap_or(0);
                        let hour: i64 = t.get(1).unwrap().as_str().parse().unwrap_or(0);
                        let minute: i64 = t.get(2).unwrap().as_str().parse().unwrap_or(0);
                        Some(format!(
                            "{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:00"
                        ))
                    }
                    _ => None,
                }
            }
            _ => None,
        };

        books.push(Book {
            id,
            title,
            hash: hash_from_href(&href),
            href: if href.is_empty() { None } else { Some(href) },
            author: None,
            cover: None,
            description: None,
            publisher: None,
            year: None,
            language: None,
            categories: None,
            pages: None,
            series: None,
            extension: None,
            filesize: None,
            filesize_string: None,
            interest_score: None,
            read_online_url: None,
            volume: None,
            isbn10: None,
            isbn13: None,
            ipfs_cid: None,
            ipfs_cid_blake2b: None,
            rating_interest: None,
            rating_quality: None,
            readlist_book_id: None,
            note: None,
            downloaded_at,
        });
    }
    books
}

// ──────────────────────────────────────────────────────────────────
// Tests — differential baseline from test/parsers/download_stats_page_test.dart
// ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    const PAGE_HTML: &str = r#"<html><body><table>
<tbody>
<tr class="dstats-row" data-item_id="23787383">
  <td class="lg-w-60 hidden-xs" style="padding-left: 16px;">1</td>
  <td class="lg-w-120" style="white-space: nowrap;">
    <span class="hidden-xs">11.11.2026</span>
    <span class="visible-xs">11.11.26</span>
    <p style="color: var(--gray-7); padding: 0;">21:02</p>
  </td>
  <td class="lg-w-530" style="max-width: 530px;">
    <div class="book-title">
      <a href="https://zh.z-library.sk/book/eOWaxzXxjb/%E7%94%B7%E4%BA%BA.html">男人就愛吃這套！讓他銷魂飛天的52招口愛技巧</a>
    </div>
  </td>
  <td class="col-buttons">
    <div class="book-rating-dstats button-element">
      <div class="book-rating " data-th=""><i class="zlibicon-star"></i></div>
    </div>
  </td>
</tr>
<tr class="dstats-row" data-item_id="30325900">
  <td class="lg-w-60 hidden-xs" style="padding-left: 16px;">2</td>
  <td class="lg-w-120" style="white-space: nowrap;">
    <span class="hidden-xs">10.11.2026</span>
    <span class="visible-xs">10.11.26</span>
    <p style="color: var(--gray-7); padding: 0;">16:45</p>
  </td>
  <td class="lg-w-530" style="max-width: 530px;">
    <div class="book-title">
      <a href="/book/0OZdLaWajd/%E4%B8%AD%E5%9B%BD%E6%B0%91%E4%BF%97%E6%B8%B8.html">中国民俗游 民间风俗自助游完全手册 （上册）</a>
    </div>
  </td>
  <td class="col-buttons">
    <div class="book-rating-dstats button-element">
      <div class="book-rating " data-th="350405ea172483af193113ba2c84ec7b"><i class="zlibicon-star"></i></div>
    </div>
  </td>
</tr>
<tr class="dstats-row">
  <td class="lg-w-60 hidden-xs">3</td>
  <td class="lg-w-120"><span class="hidden-xs">09.11.2026</span><p>10:00</p></td>
  <td class="lg-w-530"><div class="book-title"><a href="/book/aaa/无id.html">无 id 的坏行</a></div></td>
</tr>
<tr class="dstats-row" data-item_id="42">
  <td class="lg-w-60 hidden-xs">4</td>
  <td class="lg-w-120"><span class="hidden-xs">08.11.2026</span><p>10:00</p></td>
  <td class="lg-w-530"><div class="book-title"><a href="/book/bbb/空标题.html">  </a></div></td>
</tr>
<tr class="dstats-row" data-item_id="43">
  <td class="lg-w-60 hidden-xs">5</td>
  <td class="lg-w-120"><span class="hidden-xs">07.11.2026</span></td>
  <td class="lg-w-530"><div class="book-title"><a href="/book/ccc/无时间.html">缺时间戳的行</a></div></td>
</tr>
</tbody>
</table></body></html>"#;

    #[test]
    fn parses_rows_skips_bad_keeps_missing_time() {
        let books = parse_download_stats_page(PAGE_HTML);
        // Bad rows (no id, empty title) skipped; missing-timestamp kept.
        assert_eq!(books.len(), 3);

        assert_eq!(books[0].id, 23787383);
        assert_eq!(books[0].title, "男人就愛吃這套！讓他銷魂飛天的52招口愛技巧");
        assert_eq!(books[0].hash.as_deref(), Some("eOWaxzXxjb"));
        // ISO string of DateTime(2026, 11, 11, 21, 2).
        assert_eq!(books[0].downloaded_at.as_deref(), Some("2026-11-11T21:02:00"));

        assert_eq!(books[1].id, 30325900);
        assert_eq!(books[1].hash.as_deref(), Some("0OZdLaWajd"));
        assert_eq!(books[1].downloaded_at.as_deref(), Some("2026-11-10T16:45:00"));

        assert_eq!(books[2].id, 43);
        assert_eq!(books[2].title, "缺时间戳的行");
        assert_eq!(books[2].hash.as_deref(), Some("ccc"));
        assert_eq!(books[2].downloaded_at, None);
    }

    #[test]
    fn empty_page_and_wrong_row_class_parse_empty() {
        assert!(parse_download_stats_page("<html><body></body></html>").is_empty());
        // A different row class never matches.
        assert!(parse_download_stats_page(
            "<table><tr class=\"booklists-row\" data-item_id=\"1\"><td><a href=\"/book/hash/x.html\">标题</a></td></tr></table>",
        )
        .is_empty());
    }
}
