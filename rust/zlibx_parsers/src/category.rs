//! Category page parser — Rust port of
//! `vendor/olib_api_plugin/lib/src/category.dart`.
//!
//! Same card shape/scoping as the fulltext parser, but: deleted cards
//! are KEPT with a reason (like fulltext), `favorite`="1" is read
//! (category browse is the only list that carries it), `total_pages`
//! is `None` when the page has no pagerOptions (never invent a
//! total), and the search form's slug is extracted (the in-category
//! search only serves the slugged URL).

use scraper::{ElementRef, Selector};

use crate::fulltext::{attr, hash_from_href, resolve_card_url};
use crate::models::{Book, CategoryBook, CategoryPage};

/// Parse a `/category/{id}` document into its books and page count.
///
/// Mirrors `parseCategoryBooksPage(String html, {String? baseUrl})`.
pub(crate) fn parse_category_books_page(
    html: &str,
    base_url: Option<&str>,
) -> CategoryPage {
    let doc = scraper::Html::parse_document(html);
    let box_sel = Selector::parse("#searchResultBox").unwrap();
    let item_sel = Selector::parse(".book-item").unwrap();
    let card_sel = Selector::parse("z-bookcard").unwrap();
    let counter_sel = Selector::parse(".counter").unwrap();
    let img_sel = Selector::parse("img").unwrap();
    let title_sel = Selector::parse(r#"div[slot="title"]"#).unwrap();
    let author_sel = Selector::parse(r#"div[slot="author"]"#).unwrap();

    let mut cards: Vec<ElementRef> = Vec::new();
    match doc.select(&box_sel).next() {
        Some(result_box) => {
            for item in result_box.select(&item_sel) {
                if item.attr("hidden").is_some() {
                    continue;
                }
                let counter_text = item
                    .select(&counter_sel)
                    .next()
                    .map(|c| c.text().collect::<String>())
                    .unwrap_or_default();
                if counter_text.trim() == "0" {
                    continue;
                }
                if let Some(card) = item.select(&card_sel).next() {
                    cards.push(card);
                }
            }
        }
        None => {
            cards.extend(doc.select(&card_sel));
        }
    }

    let mut books = Vec::new();
    for card in cards {
        // Hidden fit template outside a wrapper: no termshash + class fit.
        let termshash = card.attr("termshash").unwrap_or("").trim().to_string();
        let is_fit = card
            .attr("class")
            .unwrap_or("")
            .split_whitespace()
            .any(|c| c == "fit");
        if termshash.is_empty() && is_fit {
            continue;
        }
        let id: i64 = match card.attr("id").unwrap_or("").trim().parse() {
            Ok(v) => v,
            Err(_) => continue,
        };
        let href = card.attr("href").unwrap_or("").trim().to_string();
        let img = card.select(&img_sel).next();
        let cover_raw = img
            .and_then(|i| {
                i.attr("data-src")
                    .map(|s| s.trim().to_string())
                    .or_else(|| i.attr("src").map(|s| s.trim().to_string()))
            })
            .unwrap_or_default();
        let title = card
            .select(&title_sel)
            .next()
            .map(|e| e.text().collect::<String>())
            .unwrap_or_default()
            .trim()
            .to_string();
        let author = card
            .select(&author_sel)
            .next()
            .map(|e| e.text().collect::<String>())
            .unwrap_or_default()
            .trim()
            .to_string();
        let deleted = card.attr("deleted").unwrap_or("").trim().to_string();
        let removed = deleted == "1" || deleted == "5" || deleted == "9";
        let reason = if !removed {
            None
        } else if deleted == "1" {
            Some("copyright".to_string())
        } else {
            Some("removed".to_string())
        };
        let cover = if cover_raw.is_empty() {
            None
        } else if let Some(base) = base_url {
            Some(resolve_card_url(&cover_raw, base))
        } else {
            Some(cover_raw)
        };
        books.push(CategoryBook {
            book: Book {
                id,
                title,
                hash: hash_from_href(&href),
                href: None,
                author: if author.is_empty() { None } else { Some(author) },
                cover,
                description: None,
                publisher: attr(&card, "publisher"),
                year: card.attr("year").unwrap_or("").trim().parse::<i64>().ok(),
                language: attr(&card, "language"),
                categories: None,
                pages: None,
                series: None,
                extension: attr(&card, "extension"),
                filesize: None,
                filesize_string: attr(&card, "filesize"),
                interest_score: attr(&card, "rating"),
                read_online_url: attr(&card, "read"),
                volume: None,
                isbn10: None,
                isbn13: None,
                ipfs_cid: None,
                ipfs_cid_blake2b: None,
                rating_interest: None,
                rating_quality: None,
                readlist_book_id: None,
                note: None,
                downloaded_at: None,
            },
            is_favorite: card.attr("favorite").unwrap_or("").trim() == "1",
            unavailable_reason: reason,
        });
    }

    // Search slug off any form whose action matches
    // /category/\d+/([^/]+)/s/ — percent-decoded, so the path builder
    // re-encodes it exactly once.
    static SLUG_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let slug_re = SLUG_RE.get_or_init(|| {
        regex::Regex::new(r"/category/\d+/([^/]+)/s/").unwrap()
    });
    let mut search_slug: Option<String> = None;
    let form_sel = Selector::parse("form").unwrap();
    'outer: for form in doc.select(&form_sel) {
        let action = form.attr("action").unwrap_or("");
        if let Some(m) = slug_re.captures(action) {
            if let Some(g) = m.get(1) {
                search_slug = Some(percent_decode(g.as_str()));
                break 'outer;
            }
        }
    }

    // total_pages: None when absent (never invent a total).
    static PAGES_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let pages_re = PAGES_RE.get_or_init(|| {
        regex::Regex::new(r"pagesTotal\s*:\s*(\d+)").unwrap()
    });
    let total_pages = pages_re
        .captures(html)
        .and_then(|m| m.get(1))
        .and_then(|m| m.as_str().parse::<i64>().ok())
        .filter(|&p| p >= 1);

    CategoryPage {
        books,
        total_pages,
        search_slug,
    }
}

/// Minimal percent-decoding, mirroring `Uri.decodeComponent` for the
/// shapes a form action carries (%XX sequences only; `+` is NOT
/// decoded to a space, same as Dart's decodeComponent).
fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hi = (b[i + 1] as char).to_digit(16);
            let lo = (b[i + 2] as char).to_digit(16);
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push(((h * 16) + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

// ──────────────────────────────────────────────────────────────────
// Tests — differential baselines from test/parsers/category_page_test.dart
// and category_books_test.dart (the _card/_page generator is ported 1:1)
// ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Port of the Dart `_card(n)` generator.
    fn card(n: u32, deleted: &str, favorite: &str, fit_template: bool) -> String {
        let termshash = if fit_template {
            String::new()
        } else {
            format!("aaaa{:x}bbbb", n)
        };
        let classes = if fit_template { " class=\"fit\"" } else { " class=\"ready\"" };
        format!(
            r#"<z-bookcard id="{id}" isbn="" termshash="{termshash}" href="/book/AbCdEfGh{nn}/Synthetic-Book-{n}" download="/dl/FAKE{nnn}" deleted="{deleted}" favorite="{favorite}" publisher="Synthetic Press" language="english" year="2021" extension="epub" filesize="1.23 MB" rating="4.5" quality="3" user_token="FAKE-TOKEN-12345" contenttypeparam=""{classes}>
  <img data-src="https://example.com/covers100/fake-cover-{n}.png">
  <div slot="title">Synthetic Book {n}</div>
  <div slot="author">Test Author {n}</div>
  <div slot="note"></div>
  <div slot="extend"></div>
</z-bookcard>"#,
            id = 90000 + n,
            nn = format!("{:0>2}", n),
            nnn = format!("{:0>3}", n),
        )
    }

    /// Port of the Dart `_page(...)` generator.
    fn page(card_count: u32, total_pages: Option<i64>, with_box: bool) -> String {
        let mut b = String::from("<html><body>");
        if let Some(tp) = total_pages {
            b.push_str(&format!(
                "<script>var pagerOptions = {{pagesTotal: {tp}, currentPage: 1}};</script>"
            ));
        }
        if with_box {
            b.push_str("<div id=\"searchResultBox\">");
            for n in 1..=card_count {
                b.push_str(&format!("<div class=\"book-item\"><div class=\"counter\">{n}</div>"));
                b.push_str(&card(n, "0", "0", false));
                b.push_str("</div>");
            }
            b.push_str("</div>");
        } else {
            for n in 1..=card_count {
                b.push_str(&card(n, "0", "0", false));
            }
        }
        b.push_str("</body></html>");
        b
    }

    #[test]
    fn fifty_card_page_parses_all_with_pager_total() {
        let html = page(50, Some(7), true);
        let p = parse_category_books_page(&html, None);
        assert_eq!(p.books.len(), 50);
        assert_eq!(p.total_pages, Some(7));
        assert_eq!(p.books[0].book.id, 90001);
        assert_eq!(p.books[0].book.title, "Synthetic Book 1");
        assert_eq!(p.books[49].book.id, 90050);
    }

    #[test]
    fn deleted_card_kept_with_reason() {
        // Card 3 with deleted=1 → kept, reason copyright.
        let mut html = String::from("<html><body><div id=\"searchResultBox\">");
        html.push_str("<div class=\"book-item\"><div class=\"counter\">1</div>");
        html.push_str(&card(3, "1", "0", false));
        html.push_str("</div></div></body></html>");
        let p = parse_category_books_page(&html, None);
        assert_eq!(p.books.len(), 1);
        assert!(p.books[0].unavailable_reason.as_deref() == Some("copyright"));
        assert!(!p.books[0].is_favorite);
    }

    #[test]
    fn favorite_flag_read() {
        let mut html = String::from("<html><body><div id=\"searchResultBox\">");
        html.push_str("<div class=\"book-item\"><div class=\"counter\">1</div>");
        html.push_str(&card(5, "0", "1", false));
        html.push_str("</div></div></body></html>");
        let p = parse_category_books_page(&html, None);
        assert!(p.books[0].is_favorite);
        assert_eq!(p.books[0].unavailable_reason, None);
    }

    #[test]
    fn fit_template_skipped() {
        let mut html = String::from("<html><body><div id=\"searchResultBox\">");
        html.push_str("<div class=\"book-item\"><div class=\"counter\">0</div>");
        html.push_str(&card(0, "0", "0", true));
        html.push_str("</div></div></body></html>");
        let p = parse_category_books_page(&html, None);
        assert!(p.books.is_empty());
    }

    #[test]
    fn missing_box_falls_back_to_document() {
        let html = page(3, None, false);
        let p = parse_category_books_page(&html, None);
        assert_eq!(p.books.len(), 3);
        assert_eq!(p.total_pages, None); // no pager → None, never invented
    }

    #[test]
    fn search_slug_extracted_and_decoded() {
        let html = "<html><body><div id=\"searchResultBox\"></div>\
<form action=\"/category/75/%E7%A7%91%E5%B9%BB/s/\" method=\"get\"></form></body></html>";
        let p = parse_category_books_page(html, None);
        assert_eq!(p.search_slug.as_deref(), Some("科幻"));
    }

    #[test]
    fn no_search_form_slug_none() {
        let html = page(1, Some(2), true);
        let p = parse_category_books_page(&html, None);
        assert_eq!(p.search_slug, None);
    }
}
