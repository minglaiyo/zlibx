//! Article search page parser — Rust port of
//! `vendor/olib_api_plugin/lib/src/article_search.dart`.
//!
//! The card shape is the SAME as the full-text page; differences from
//! the fulltext parser are: the dedicated [`Article`] model (with the
//! card's `download`/`quality` attributes), NO fit-class check (the
//! hidden fit card is filtered via the wrapper's `hidden`/counter-0,
//! and `termshash` is deliberately not read), and the total regex
//! accepting both the zh (`文章`) and English (`Articles`) tab labels.

use crate::sel;
use scraper::{ElementRef, Selector};

use crate::fulltext::{attr, hash_from_href, pages_re, resolve_card_url};
use crate::models::{Article, ArticleSearchPage};

// ──────────────────────────────────────────────────────────────────
// Public entry points (bridged to Dart via #[frb])
// ──────────────────────────────────────────────────────────────────

/// Parse one page of article search results.
///
/// Mirrors `parseArticleSearchPage(String html, {String? baseUrl})`.
pub(crate) fn parse_article_search_page(
    html: &str,
    base_url: Option<&str>,
) -> ArticleSearchPage {
    let doc = scraper::Html::parse_document(html);

    let box_sel = sel!("#searchResultBox");
    let item_sel = sel!(".book-item");
    let card_sel = sel!("z-bookcard");
    let counter_sel = sel!(".counter");
    let img_sel = sel!("img");
    let title_sel = sel!(r#"div[slot="title"]"#);
    let author_sel = sel!(r#"div[slot="author"]"#);

    // Same scoping/fallback as the full-text parser: cards live in
    // `#searchResultBox`; fall back to the whole document when absent.
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

    let mut articles: Vec<Article> = Vec::new();
    for card in cards {
        // id must parse as an integer; skip cards without one (this
        // also drops any fit template that slipped past the wrapper
        // filter — same behavior as Dart's int.tryParse skip).
        let id: i64 = match card.attr("id").unwrap_or("").trim().parse() {
            Ok(v) => v,
            Err(_) => continue,
        };

        let href_raw = card.attr("href").unwrap_or("").trim().to_string();
        let href = if href_raw.is_empty() {
            None
        } else {
            Some(href_raw.clone())
        };
        let url = if href_raw.is_empty() {
            None
        } else {
            Some(match base_url {
                Some(base) => resolve_card_url(&href_raw, base),
                None => href_raw.clone(),
            })
        };

        let img = card.select(&img_sel).next();
        let cover_raw = img
            .and_then(|i| {
                i.attr("data-src")
                    .map(|s| s.trim().to_string())
                    .or_else(|| i.attr("src").map(|s| s.trim().to_string()))
            })
            .unwrap_or_default();
        let cover = if cover_raw.is_empty() {
            None
        } else if let Some(base) = base_url {
            Some(resolve_card_url(&cover_raw, base))
        } else {
            Some(cover_raw)
        };

        let download_raw = card.attr("download").unwrap_or("").trim().to_string();
        let download_path = if download_raw.is_empty() {
            None
        } else if let Some(base) = base_url {
            Some(resolve_card_url(&download_raw, base))
        } else {
            Some(download_raw)
        };

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

        articles.push(Article {
            id,
            title,
            href,
            url,
            hash: hash_from_href(&href_raw),
            author: if author.is_empty() { None } else { Some(author) },
            cover,
            publisher: attr(&card, "publisher"),
            year: card.attr("year").unwrap_or("").trim().parse::<i64>().ok(),
            language: attr(&card, "language"),
            extension: attr(&card, "extension"),
            filesize_string: attr(&card, "filesize"),
            rating: attr(&card, "rating"),
            quality: attr(&card, "quality"),
            download_path,
            removed,
            unavailable_reason: reason,
        });
    }

    let total = parse_article_total(html).unwrap_or_else(|| articles.len() as i64);
    let total_pages = parse_total_pages(html);

    ArticleSearchPage {
        articles,
        total,
        total_pages,
    }
}

/// The query a results page's search form echoes back (wrong-page
/// guard). Mirrors `extractArticleSearchQuery` — same implementation
/// as the full-text one.
pub(crate) fn extract_article_search_query(html: &str) -> Option<String> {
    let doc = scraper::Html::parse_document(html);
    let sel = sel!(r#"input[name="q"]"#);
    let value = doc
        .select(&sel)
        .next()
        .and_then(|e| e.attr("value"))
        .map(|s| s.trim().to_string())?;
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

// ──────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────

/// The total from the mode-tab text (`文章 (N)` / `Articles (N)`).
/// Compiled once (see the fulltext regex-cache note).
///
/// Mirrors `_parseArticleTotal`.
fn parse_article_total(html: &str) -> Option<i64> {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let re = RE.get_or_init(|| {
        regex::Regex::new(r"(?:文章|Articles)(?:\s|&nbsp;|&#160;)*\((\d+)\+?\)")
            .unwrap()
    });
    re.captures(html)
        .and_then(|m| m.get(1))
        .and_then(|m| m.as_str().parse::<i64>().ok())
}

fn parse_total_pages(html: &str) -> i64 {
    let re = pages_re();
    re.captures(html)
        .and_then(|m| m.get(1))
        .and_then(|m| m.as_str().parse::<i64>().ok())
        .filter(|&p| p >= 1)
        .unwrap_or(1)
}

// ──────────────────────────────────────────────────────────────────
// Tests — differential baseline from test/parsers/article_search_test.dart
// ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    const RESULTS_HTML: &str = r#"<html><body>
<div class="search-results-tabs-panel">
  <ul id="searchModeTabs">
    <li class="active">文章&nbsp;(3)</li>
  </ul>
</div>
<div id="searchResultBox">
  <div class="book-item resItemBoxBooks ">
    <div class="counter">1</div>
    <z-bookcard id="91001" isbn="" termshash="aaaa1111bbbb2222cccc3333dddd4444" href="/book/AbCdEfGh12/Synthetic-Article-One.html" download="/dl/FAKE001" deleted="0" publisher="" language="中文" year="" extension="pdf" filesize="1.31 MB" rating="0.0" quality="4" user_token="<redacted>" contenttypeparam="?content_type=article" class="ready">
      <img data-src="https://example.com/covers100/fake-cover-1.png">
      <div slot="title">Synthetic Article One: Third Party Wealth Management</div>
      <div slot="author">Synthetic Securities Co., Ltd.</div>
      <div slot="note"></div>
      <div slot="extend"></div>
    </z-bookcard>
  </div>
  <z-promotion book="" async="" id="null" class="ready" demo=""></z-promotion>
  <div class="book-item resItemBoxBooks">
    <div class="counter">2</div>
    <z-bookcard id="91002" isbn="" termshash="eeee5555ffff6666aaaa7777bbbb8888" href="/book/WxYz0987Ab/Synthetic-Article-Two.html" download="/dl/FAKE002" deleted="0" publisher="Synthetic Journal" language="english" year="2014" extension="pdf" filesize="7.11 MB" rating="4.9" quality="5.0" user_token="<redacted>" contenttypeparam="?content_type=article" class="fit ready">
      <img data-src="">
      <div slot="title">Synthetic Article Two</div>
      <div slot="author">Test Author Beta</div>
      <div slot="note"></div>
      <div slot="extend"></div>
    </z-bookcard>
  </div>
  <div class="book-item resItemBoxBooks ">
    <div class="counter">3</div>
    <z-bookcard id="91003" isbn="" termshash="1234abcd5678efgh9012ijkl3456mnop" href="/book/MnOp3456Qr/Synthetic-Copyright-Article-Three.html" download="" deleted="1" publisher="Synthetic Press" language="" year="" extension="pdf" filesize="0.50 MB" rating="3.0" quality="1" user_token="<redacted>" contenttypeparam="?content_type=article" class="ready">
      <img data-src="/covers100/fake-relative-cover-3.png">
      <div slot="title">Synthetic Copyright Article Three</div>
      <div slot="author">Test Author Gamma</div>
      <div slot="note"></div>
      <div slot="extend"></div>
    </z-bookcard>
  </div>
  <div class="book-item resItemBoxBooks" hidden aria-hidden="true">
    <div class="counter">0</div>
    <z-bookcard id="99999" isbn="" href="/book/FitTemplate00/synthetic-query-text.html" download="" deleted="0" class="fit ready">
      <div slot="title">synthetic query text</div>
      <div slot="author">synthetic query text</div>
    </z-bookcard>
  </div>
</div>
</body></html>"#;

    const BARE_HTML: &str = r#"<html><body>
<div id="searchResultBox">
  <div class="book-item resItemBoxBooks ">
    <div class="counter">1</div>
    <z-bookcard id="92001" isbn="" href="/book/BareHash0001/Bare-Synthetic-Article.html" download="/dl/FAKE003" deleted="0" extension="pdf" filesize="2.00 MB" class="ready">
      <img data-src="https://example.com/covers100/fake-cover-4.png">
      <div slot="title">Bare Synthetic Article</div>
      <div slot="author">Test Author Delta</div>
    </z-bookcard>
  </div>
</div>
</body></html>"#;

    const ENGLISH_TAB_HTML: &str = "<html><body><div id=\"searchModeTabs\"><li class=\"active\">Articles&nbsp;(150+)</li></div><div id=\"searchResultBox\"></div></body></html>";

    const RESULTS_HTML_WITH_PAGER: &str = "<html><body><div id=\"searchResultBox\"></div><script>var pagerOptions = {pagesTotal: 5, pagesSpan: 5, pageCurrent: 1};</script></body></html>";

    #[test]
    fn parses_articles_skips_hidden_fit_and_ad_slot() {
        let page = parse_article_search_page(RESULTS_HTML, None);
        assert_eq!(page.articles.len(), 3);
        let ids: Vec<i64> = page.articles.iter().map(|a| a.id).collect();
        assert_eq!(ids, vec![91001, 91002, 91003]);
        // The tab count (3), not the raw card count (4, fit included).
        assert_eq!(page.total, 3);
    }

    #[test]
    fn maps_every_card_attribute() {
        let page = parse_article_search_page(RESULTS_HTML, None);
        let first = &page.articles[0];
        assert_eq!(
            first.title,
            "Synthetic Article One: Third Party Wealth Management"
        );
        assert_eq!(first.author.as_deref(), Some("Synthetic Securities Co., Ltd."));
        assert_eq!(first.hash.as_deref(), Some("AbCdEfGh12"));
        assert_eq!(
            first.href.as_deref(),
            Some("/book/AbCdEfGh12/Synthetic-Article-One.html")
        );
        // No baseUrl → url stays relative.
        assert_eq!(
            first.url.as_deref(),
            Some("/book/AbCdEfGh12/Synthetic-Article-One.html")
        );
        assert_eq!(
            first.cover.as_deref(),
            Some("https://example.com/covers100/fake-cover-1.png")
        );
        assert_eq!(first.publisher, None); // empty attribute → None
        assert_eq!(first.year, None); // empty attribute → None
        assert_eq!(first.language.as_deref(), Some("中文"));
        assert_eq!(first.extension.as_deref(), Some("pdf"));
        assert_eq!(first.filesize_string.as_deref(), Some("1.31 MB"));
        assert_eq!(first.rating.as_deref(), Some("0.0"));
        assert_eq!(first.quality.as_deref(), Some("4"));
        assert_eq!(first.download_path.as_deref(), Some("/dl/FAKE001"));
        assert_eq!(first.removed, false);
        assert_eq!(first.unavailable_reason, None);
    }

    #[test]
    fn resolves_href_cover_and_download_against_base() {
        let page =
            parse_article_search_page(RESULTS_HTML, Some("https://zh.z-library.sk"));
        let first = &page.articles[0];
        assert_eq!(
            first.url.as_deref(),
            Some("https://zh.z-library.sk/book/AbCdEfGh12/Synthetic-Article-One.html")
        );
        let third = &page.articles[2];
        assert_eq!(
            third.cover.as_deref(),
            Some("https://zh.z-library.sk/covers100/fake-relative-cover-3.png")
        );
    }

    #[test]
    fn keeps_removed_card_flags_and_clears_download() {
        let page = parse_article_search_page(RESULTS_HTML, None);
        let removed = &page.articles[2];
        assert_eq!(removed.removed, true);
        assert_eq!(removed.unavailable_reason.as_deref(), Some("copyright"));
        assert_eq!(removed.download_path, None); // empty download attribute
        assert_eq!(removed.publisher.as_deref(), Some("Synthetic Press"));
        assert_eq!(removed.quality.as_deref(), Some("1"));
    }

    #[test]
    fn parses_year_publisher_and_empty_cover() {
        let page = parse_article_search_page(RESULTS_HTML, None);
        let second = &page.articles[1];
        assert_eq!(second.year, Some(2014));
        assert_eq!(second.publisher.as_deref(), Some("Synthetic Journal"));
        assert_eq!(second.language.as_deref(), Some("english"));
        assert_eq!(second.rating.as_deref(), Some("4.9"));
        assert_eq!(second.quality.as_deref(), Some("5.0"));
        assert_eq!(second.cover, None); // empty data-src → None
    }

    #[test]
    fn falls_back_to_card_count_and_1_page() {
        let page = parse_article_search_page(BARE_HTML, None);
        assert_eq!(page.articles.len(), 1);
        assert_eq!(page.articles[0].id, 92001);
        assert_eq!(page.articles[0].hash.as_deref(), Some("BareHash0001"));
        assert_eq!(page.articles[0].title, "Bare Synthetic Article");
        assert_eq!(page.total, 1);
        assert_eq!(page.total_pages, 1);
    }

    #[test]
    fn reads_english_tab_label_and_trailing_plus() {
        let page = parse_article_search_page(ENGLISH_TAB_HTML, None);
        assert_eq!(page.total, 150);
    }

    #[test]
    fn reads_total_pages_from_pager_options() {
        let page = parse_article_search_page(RESULTS_HTML_WITH_PAGER, None);
        assert_eq!(page.total_pages, 5);
    }

    #[test]
    fn extract_query_returns_echoed_query() {
        let html = "<html><body><form id=\"searchForm\" action=\"/s/\">\
<input type=\"text\" maxlength=\"200\" name=\"q\" id=\"searchFieldx\" value=\"synthetic query\">\
</form></body></html>";
        assert_eq!(
            extract_article_search_query(html),
            Some("synthetic query".to_string())
        );
    }

    #[test]
    fn extract_query_null_without_q_input() {
        assert_eq!(
            extract_article_search_query("<html><body><form></form></body></html>"),
            None
        );
    }
}
