//! Full-text search page parser — Rust port of
//! `vendor/olib_api_plugin/lib/src/fulltext.dart`.
//!
//! Uses `scraper` (html5ever + CSS selector engine) to mirror Dart's
//! `package:html` queries, and `regex` for the inline-script/text
//! extractions (total count, pagesTotal, token format) done on the raw
//! HTML string in Dart.

use crate::sel;
use scraper::{ElementRef, Node, Selector};

use crate::models::{Book, FullTextHit, FullTextSearchPage, FullTextSnippetPart};

// ──────────────────────────────────────────────────────────────────
// Public entry points (bridged to Dart via #[frb])
// ──────────────────────────────────────────────────────────────────

/// Parse one page of full-text search results.
///
/// Mirrors `parseFullTextSearchPage(String html, {String? baseUrl})`.
pub(crate) fn parse_fulltext_search_page(
    html: &str,
    base_url: Option<&str>,
) -> FullTextSearchPage {
    let doc = scraper::Html::parse_document(html);

    let box_sel = sel!("#searchResultBox");
    let item_sel = sel!(".book-item");
    let card_sel = sel!("z-bookcard");
    let counter_sel = sel!(".counter");
    let img_sel = sel!("img");
    let title_sel = sel!(r#"div[slot="title"]"#);
    let author_sel = sel!(r#"div[slot="author"]"#);

    // Cards live in `#searchResultBox`; scope the query to it so a card
    // elsewhere cannot leak. Fall back to the whole document when the
    // box is absent (page-shape change).
    let mut cards: Vec<ElementRef> = Vec::new();
    match doc.select(&box_sel).next() {
        Some(result_box) => {
            for item in result_box.select(&item_sel) {
                // Skip the hidden fit template wrapper.
                if item.attr("hidden").is_some() {
                    continue;
                }
                // Skip items whose counter reads 0.
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

    let mut hits: Vec<FullTextHit> = Vec::new();
    for card in cards {
        // Hidden fit template outside a `.book-item` wrapper: no
        // `termshash` and class `fit`.
        let termshash = card.attr("termshash").unwrap_or("").trim().to_string();
        let class_attr = card.attr("class").unwrap_or("");
        let is_fit = class_attr.split_whitespace().any(|c| c == "fit");
        if termshash.is_empty() && is_fit {
            continue;
        }

        // id must parse as an integer; skip cards without one.
        let id: i64 = match card.attr("id").unwrap_or("").trim().parse() {
            Ok(v) => v,
            Err(_) => continue,
        };

        let href = card.attr("href").unwrap_or("").trim().to_string();

        // Cover: `data-src` preferred, `src` fallback.
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

        let book = Book {
            id,
            title,
            hash: hash_from_href(&href),
            href: Some(href),
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
        };

        hits.push(FullTextHit {
            book,
            snippet: parse_snippet(&card),
            removed,
            unavailable_reason: reason,
        });
    }

    let total = parse_total(html).unwrap_or_else(|| hits.len() as i64);
    let total_pages = parse_total_pages(html);

    FullTextSearchPage {
        hits,
        total,
        total_pages,
    }
}

/// Extract the session's full-text token from a search page's HTML.
///
/// Mirrors `extractFulltextToken(String html)`. Returns `None` when the
/// page carries no token input, or the value is not an 8-hex token.
pub(crate) fn extract_fulltext_token(html: &str) -> Option<String> {
    let doc = scraper::Html::parse_document(html);
    let sel = sel!(r#"input[name="token"]"#);
    let value = doc
        .select(&sel)
        .next()
        .and_then(|e| e.attr("value"))
        .map(|s| s.trim().to_string())?;
    if value.is_empty() {
        return None;
    }
    let re = token_re();
    if re.is_match(&value) {
        Some(value)
    } else {
        None
    }
}

/// Extract the query a results page's search form echoes back.
///
/// Mirrors `extractFulltextQuery(String html)`. Returns `None` when the
/// page carries no `q` input (or its value is empty). The parser
/// entity-decodes the value, so it compares directly against the
/// submitted query.
pub(crate) fn extract_fulltext_query(html: &str) -> Option<String> {
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

// Compiled-once regexes: `regex::Regex::new` is expensive (NFA build),
// and Dart's RegExp literals are comparatively cheap — without these
// caches the Rust side re-compiled `\s+` per snippet node and the
// whole-parse regexes per call, dominating the runtime (bench-proven
// 2026-11-16: 21.8ms → 4.7ms per 50-hit page).
fn ws_re() -> &'static regex::Regex {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r"\s+").unwrap())
}

fn total_re() -> &'static regex::Regex {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| {
        regex::Regex::new(r"全文检索(?:\s|&nbsp;|&#160;)*\((\d+)\+?\)").unwrap()
    })
}

pub(crate) fn pages_re() -> &'static regex::Regex {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r"pagesTotal\s*:\s*(\d+)").unwrap())
}

fn token_re() -> &'static regex::Regex {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r"^[0-9a-fA-F]{8}$").unwrap())
}

/// Read an attribute, trim, return `None` when empty.
///
/// Mirrors `_attr(dom.Element el, String name)`.
pub(crate) fn attr(el: &ElementRef, name: &str) -> Option<String> {
    el.attr(name)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Book hash from a `/book/{hash}/{slug}.html` href, or `None` when the
/// href does not have that shape. Mirrors `_hashFromHref` /
/// `Book.hashFromBookHref`.
pub(crate) fn hash_from_href(href: &str) -> Option<String> {
    // Dart's Uri.pathSegments covers ONLY the path, so absolute URLs
    // like `https://host/book/{hash}/…` work too: strip scheme://host
    // for absolute URLs; relative hrefs pass through. (Differential-
    // test-proven via the dstats absolute-link fixture.)
    let after_scheme = match href.find("://") {
        Some(i) => &href[i + 3..],
        None => href,
    };
    // Keep from the first '/' onward (the path part).
    let path = match after_scheme.find('/') {
        Some(i) => &after_scheme[i..],
        None => "",
    };
    // Strip query string and fragment.
    let path = path.split(['?', '#']).next().unwrap_or(path);
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    if segments.len() >= 2 && segments[0] == "book" {
        let hash = segments[1];
        if !hash.is_empty() {
            return Some(hash.to_string());
        }
    }
    None
}

/// Resolve a cover URL against the page's base URL.
///
/// Mirrors `_resolveCardUrl`: http/https passthrough, `//` → `https:…`,
/// `/` → `$baseUrl$raw`, else passthrough.
pub(crate) fn resolve_card_url(raw: &str, base_url: &str) -> String {
    if raw.starts_with("http://") || raw.starts_with("https://") {
        raw.to_string()
    } else if raw.starts_with("//") {
        format!("https:{}", raw)
    } else if raw.starts_with('/') {
        format!("{}{}", base_url, raw)
    } else {
        raw.to_string()
    }
}

/// The matching passage: `.hulltext .ft_highlight .ft_highlight_part`,
/// split on `<em>` into highlighted/plain runs. Whitespace folds to a
/// single space; leading/trailing whitespace is trimmed only at the
/// passage edges.
///
/// Mirrors `_parseSnippet`.
fn parse_snippet(card: &ElementRef) -> Vec<FullTextSnippetPart> {
    let sel =
        sel!(".hulltext .ft_highlight .ft_highlight_part");
    let part = match card.select(&sel).next() {
        Some(p) => p,
        None => return Vec::new(),
    };

    let mut parts: Vec<FullTextSnippetPart> = Vec::new();
    for node_ref in part.children() {
        let is_em = match node_ref.value() {
            Node::Element(el) => el.name.local.as_ref() == "em",
            _ => false,
        };

        let text: String = if is_em {
            // Element node: create ElementRef from the NodeRef and
            // collect all descendant text.
            let el_ref = ElementRef::wrap(node_ref.clone()).unwrap();
            el_ref.text().collect::<String>()
        } else {
            // Text node: take the text directly.
            match node_ref.value() {
                Node::Text(text) => text.to_string(),
                _ => continue,
            }
        };

        // Fold whitespace runs to a single space, matching Dart's
        // `replaceAll(RegExp(r'\s+'), ' ')`. Unlike split_whitespace,
        // this preserves leading/trailing spaces (Dart keeps them).
        let folded = ws_re().replace_all(&text, " ").to_string();
        if folded.trim().is_empty() {
            continue;
        }
        parts.push(FullTextSnippetPart {
            text: folded,
            highlighted: is_em,
        });
    }

    if parts.is_empty() {
        return Vec::new();
    }

    // Trim left of the first run, trim right of the last run (only when
    // there is more than one run, matching Dart's `if (parts.length > 1)`).
    let n = parts.len();
    parts
        .into_iter()
        .enumerate()
        .map(|(i, p)| {
            let text = if i == 0 {
                p.text.trim_start().to_string()
            } else if i == n - 1 && n > 1 {
                p.text.trim_end().to_string()
            } else {
                p.text
            };
            FullTextSnippetPart {
                text,
                highlighted: p.highlighted,
            }
        })
        .collect()
}

/// The total from the tab text (`全文检索 (N)`). Accepts raw whitespace,
/// `&nbsp;` and `&#160;`. Large totals render with a trailing `+`.
/// Returns `None` when the tab is absent.
///
/// Mirrors `_parseTotal`.
fn parse_total(html: &str) -> Option<i64> {
    let re = total_re();
    re.captures(html)
        .and_then(|m| m.get(1))
        .and_then(|m| m.as_str().parse::<i64>().ok())
}

/// Pages from the `pagerOptions` script (`pagesTotal: N`) when present,
/// else 1.
///
/// Mirrors `_parseTotalPages`.
fn parse_total_pages(html: &str) -> i64 {
    let re = pages_re();
    re.captures(html)
        .and_then(|m| m.get(1))
        .and_then(|m| m.as_str().parse::<i64>().ok())
        .filter(|&p| p >= 1)
        .unwrap_or(1)
}

// ──────────────────────────────────────────────────────────────────
// Tests — differential baseline from test/parsers/fulltext_test.dart
// ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Same synthetic fixture as `_resultsHtml` in fulltext_test.dart:
    /// 3 real hits, 1 hidden fit template, 1 ad slot, tab total 3, 2 pages.
    const RESULTS_HTML: &str = r#"<html><body>
<div class="search-results-tabs-panel">
  <ul id="subprojectsSearch">
    <li class="active">全文检索&nbsp;(3)</li>
  </ul>
</div>
<div id="searchResultBox">
  <div class="book-item resItemBoxBooks ">
    <div class="counter">1</div>
    <z-bookcard id="91001" isbn="" termshash="aaaa1111bbbb2222cccc3333dddd4444" href="/book/AbCdEfGh12/Synthetic-Phrase-Book-One.html" download="/dl/FAKE001" deleted="0" publisher="Synthetic Press" language="english" year="2021" extension="epub" filesize="1.23 MB" rating="4.5" quality="3" user_token="<redacted>" contenttypeparam="" class="ready">
      <img data-src="https://example.com/covers100/fake-cover-1.png">
      <div slot="title">Synthetic Phrase Book One</div>
      <div slot="author">Test Author Alpha</div>
      <div slot="note"></div>
      <div slot="extend">
        <div class="hulltext">
          <div class="ft_highlight">
            <div class="ft_highlight_part">… a plain lead
            <em>synthetic matching phrase</em>
            and a plain tail. …</div>
          </div>
        </div>
      </div>
    </z-bookcard>
  </div>
  <z-promotion book="" async="" id="null" class="ready" demo=""></z-promotion>
  <div class="book-item resItemBoxBooks ">
    <div class="counter">2</div>
    <z-bookcard id="91002" isbn="" termshash="eeee5555ffff6666aaaa7777bbbb8888" href="/book/WxYz0987Ab/Synthetic-Words-Book-Two.html" download="/dl/FAKE002" deleted="9" publisher="" language="english" year="2019" extension="pdf" filesize="9.87 MB" rating="0.0" quality="0" user_token="<redacted>" contenttypeparam="" class="ready">
      <img data-src="https://example.com/covers100/fake-cover-2.png">
      <div slot="title">Synthetic Words Book Two</div>
      <div slot="author">Test Author Beta</div>
      <div slot="note"></div>
      <div slot="extend">
        <div class="hulltext">
          <div class="ft_highlight">
            <div class="ft_highlight_part"><em>first</em> middle <em>second</em></div>
          </div>
        </div>
      </div>
    </z-bookcard>
  </div>
  <div class="book-item resItemBoxBooks ">
    <div class="counter">3</div>
    <z-bookcard id="91003" isbn="" termshash="1234abcd5678efgh9012ijkl3456mnop" href="/book/MnOp3456Qr/Synthetic-Copyright-Book-Three.html" download="" deleted="1" publisher="Synthetic Press" language="" year="" extension="mobi" filesize="0.50 MB" rating="3.0" quality="1" user_token="<redacted>" contenttypeparam="" class="ready">
      <img data-src="https://example.com/covers100/fake-cover-3.png">
      <div slot="title">Synthetic Copyright Book Three</div>
      <div slot="author">Test Author Gamma</div>
      <div slot="note"></div>
      <div slot="extend">
      </div>
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
<script>var pagerOptions = {pagesTotal: 2, pagesSpan: 5, pageCurrent: 1, baseUrl: '/fulltext/'};</script>
</body></html>"#;

    const TOKEN_HTML: &str = r#"<html><body>
<form method="get" id="searchForm" action="/fulltext/">
  <input type="hidden" name="token" value="abcdef12">
  <input type="text" name="q" value="">
</form>
</body></html>"#;

    #[test]
    fn parses_hits_skips_hidden_fit_and_ad_slot() {
        let page = parse_fulltext_search_page(RESULTS_HTML, None);
        assert_eq!(page.hits.len(), 3);
        let ids: Vec<i64> = page.hits.iter().map(|h| h.book.id).collect();
        assert_eq!(ids, vec![91001, 91002, 91003]);
    }

    #[test]
    fn total_from_tab_total_pages_from_pager() {
        let page = parse_fulltext_search_page(RESULTS_HTML, None);
        assert_eq!(page.total, 3);
        assert_eq!(page.total_pages, 2);
    }

    #[test]
    fn total_parses_capped_150_plus() {
        let html = RESULTS_HTML.replace("全文检索&nbsp;(3)", "全文检索&nbsp;(150+)");
        let page = parse_fulltext_search_page(&html, None);
        assert_eq!(page.total, 150);
    }

    #[test]
    fn parses_card_fields_and_hash_from_href() {
        let page = parse_fulltext_search_page(RESULTS_HTML, None);
        let book = &page.hits[0].book;
        assert_eq!(book.title, "Synthetic Phrase Book One");
        assert_eq!(book.author.as_deref(), Some("Test Author Alpha"));
        assert_eq!(book.hash.as_deref(), Some("AbCdEfGh12"));
        assert_eq!(book.publisher.as_deref(), Some("Synthetic Press"));
        assert_eq!(book.year, Some(2021));
        assert_eq!(book.language.as_deref(), Some("english"));
        assert_eq!(book.extension.as_deref(), Some("epub"));
        assert_eq!(book.filesize_string.as_deref(), Some("1.23 MB"));
        assert_eq!(book.interest_score.as_deref(), Some("4.5"));
        assert_eq!(
            book.cover.as_deref(),
            Some("https://example.com/covers100/fake-cover-1.png")
        );
    }

    #[test]
    fn splits_snippet_on_em_and_folds_whitespace() {
        let page = parse_fulltext_search_page(RESULTS_HTML, None);
        let snippet = &page.hits[0].snippet;
        let texts: Vec<&str> = snippet.iter().map(|p| p.text.as_str()).collect();
        assert_eq!(
            texts,
            vec!["… a plain lead ", "synthetic matching phrase", " and a plain tail. …"]
        );
        let flags: Vec<bool> = snippet.iter().map(|p| p.highlighted).collect();
        assert_eq!(flags, vec![false, true, false]);
    }

    #[test]
    fn handles_several_em_runs_words_mode() {
        let page = parse_fulltext_search_page(RESULTS_HTML, None);
        let snippet = &page.hits[1].snippet;
        let texts: Vec<&str> = snippet.iter().map(|p| p.text.as_str()).collect();
        assert_eq!(texts, vec!["first", " middle ", "second"]);
        let flags: Vec<bool> = snippet.iter().map(|p| p.highlighted).collect();
        assert_eq!(flags, vec![true, false, true]);
    }

    #[test]
    fn marks_deleted_cards_removed_with_reason() {
        let page = parse_fulltext_search_page(RESULTS_HTML, None);
        assert_eq!(page.hits[0].removed, false);
        assert_eq!(page.hits[0].unavailable_reason, None);
        assert_eq!(page.hits[1].removed, true);
        assert_eq!(page.hits[1].unavailable_reason.as_deref(), Some("removed"));
        assert_eq!(page.hits[2].removed, true);
        assert_eq!(
            page.hits[2].unavailable_reason.as_deref(),
            Some("copyright")
        );
    }

    #[test]
    fn card_without_highlight_has_empty_snippet() {
        let page = parse_fulltext_search_page(RESULTS_HTML, None);
        assert!(page.hits[2].snippet.is_empty());
    }

    #[test]
    fn never_reads_user_token_jwt() {
        let page = parse_fulltext_search_page(RESULTS_HTML, None);
        for hit in &page.hits {
            let book = &hit.book;
            assert!(!book.title.contains("<redacted>"));
            assert!(book.author.as_deref().map_or(true, |a| !a.contains("<redacted>")));
            assert!(book.cover.as_deref().map_or(true, |c| !c.contains("<redacted>")));
            assert!(book.hash.as_deref().map_or(true, |h| !h.contains("<redacted>")));
        }
    }

    #[test]
    fn total_falls_back_to_hit_count_when_tab_missing() {
        let html = RESULTS_HTML.replace("全文检索&nbsp;(3)", "全文检索");
        let page = parse_fulltext_search_page(&html, None);
        assert_eq!(page.total, 3);
    }

    #[test]
    fn total_pages_defaults_to_1_without_pager() {
        let html = RESULTS_HTML.replace(
            "<script>var pagerOptions = {pagesTotal: 2, pagesSpan: 5, pageCurrent: 1, baseUrl: '/fulltext/'};</script>",
            "",
        );
        let page = parse_fulltext_search_page(&html, None);
        assert_eq!(page.total_pages, 1);
    }

    #[test]
    fn extract_token_reads_hidden_field() {
        assert_eq!(extract_fulltext_token(TOKEN_HTML), Some("abcdef12".to_string()));
    }

    #[test]
    fn extract_token_returns_none_when_missing() {
        assert_eq!(
            extract_fulltext_token("<html><body><form></form></body></html>"),
            None
        );
    }

    #[test]
    fn extract_token_returns_none_for_malformed() {
        for bad in ["xyz", "abc123", "gggggggg", "abcdef123"] {
            let html = format!(
                "<html><body><input type=\"hidden\" name=\"token\" value=\"{}\"></body></html>",
                bad
            );
            assert_eq!(extract_fulltext_token(&html), None, "bad={}", bad);
        }
    }

    #[test]
    fn extract_query_reads_q_input() {
        let html = "<html><body><form id=\"searchForm\"><input type=\"text\" name=\"q\" value=\"synthetic phrase\"></form></body></html>";
        assert_eq!(
            extract_fulltext_query(html),
            Some("synthetic phrase".to_string())
        );
    }

    #[test]
    fn extract_query_returns_none_when_missing_or_empty() {
        assert_eq!(
            extract_fulltext_query("<html><body><form></form></body></html>"),
            None
        );
        assert_eq!(extract_fulltext_query(TOKEN_HTML), None);
    }

    #[test]
    fn extract_query_decodes_entities() {
        let html = "<html><body><form id=\"searchForm\"><input type=\"text\" name=\"q\" value=\"a &amp; b\"></form></body></html>";
        assert_eq!(extract_fulltext_query(html), Some("a & b".to_string()));
    }

    /// Phase 2 timing baseline: parse a synthetic 50-hit page (the
    /// real search page size) N times and print the per-run average.
    /// The Dart twin lives in test/parsers/fulltext_bench_test.dart;
    /// both build the IDENTICAL page, so the printed averages compare.
    #[test]
    fn bench_parse_50_hits() {
        let html = build_bench_page_50();
        assert_eq!(
            parse_fulltext_search_page(&html, None).hits.len(),
            50,
            "bench page must parse to 50 hits"
        );
        // Warm-up (allocator, regex caches, first-touch pages).
        let _ = parse_fulltext_search_page(&html, None);
        const N: u32 = 100;
        let start = std::time::Instant::now();
        for _ in 0..N {
            let page = parse_fulltext_search_page(&html, None);
            assert_eq!(page.hits.len(), 50);
        }
        let elapsed = start.elapsed();
        println!(
            "BENCH rust: {N} runs, {elapsed:?} total, {:?} per run (50-hit page)",
            elapsed / N
        );
    }

    /// Shared with the Dart bench twin: 50 synthetic cards, same shape
    /// as RESULTS_HTML (title/author/snippet/attributes on every card).
    fn build_bench_page_50() -> String {
        let mut html = String::from(
            "<html><body><div class=\"search-results-tabs-panel\">\
             <ul id=\"subprojectsSearch\"><li class=\"active\">\
             \u{5168}\u{6587}\u{68c0}\u{7d22}&nbsp;(50)</li></ul></div>\
             <div id=\"searchResultBox\">",
        );
        for i in 0..50u32 {
            html.push_str(&format!(
                "<div class=\"book-item\"><div class=\"counter\">{n}</div>\
<z-bookcard id=\"{id}\" termshash=\"t{i:032}\" href=\"/book/BenchHash{i:02}/Bench-Book-{i}.html\" download=\"/dl/B{i}\" deleted=\"{del}\" publisher=\"Bench Press\" language=\"english\" year=\"2020\" extension=\"epub\" filesize=\"1.00 MB\" rating=\"4.0\" quality=\"3\" user_token=\"<redacted>\" class=\"ready\">\
<img data-src=\"https://example.com/covers100/bench-{i}.png\">\
<div slot=\"title\">Bench Book {i}</div>\
<div slot=\"author\">Author {i}</div>\
<div slot=\"extend\"><div class=\"hulltext\"><div class=\"ft_highlight\"><div class=\"ft_highlight_part\">plain lead <em>match {i}</em> plain tail.</div></div></div></div>\
</z-bookcard></div>",
                n = i + 1,
                id = 90000 + i,
                del = if i % 10 == 9 { 9 } else { 0 },
                i = i,
            ));
        }
        html.push_str(
            "</div><script>var pagerOptions = {pagesTotal: 3, pagesSpan: 5};</script></body></html>",
        );
        html
    }
}
