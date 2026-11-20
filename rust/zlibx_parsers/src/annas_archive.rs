//! Anna's Archive parser — Rust port of `lib/core/annas_archive.dart`
//! (`ArchiveParsing`).
//!
//! Ported from warreth/OpenlibExtended (AGPL-3.0); zlibx is AGPL-3.0.
//! Pure parsing + URL building, shared by the app and (historically)
//! the CLI. Notable Rust-side details:
//! - `visible_text` skips script/style subtrees (html5ever keeps their
//!   source in `.text()`, same problem Dart's package:html has).
//! - `resolve_url` / `resolve_relative` use the `url` crate's RFC-3986
//!   join, matching Dart's `Uri.resolve`.
//! - The md5-link fallback dedupes containers by ego-tree NodeId,
//!   matching Dart's Set-by-element-identity.

use crate::sel;
use std::collections::HashSet;

use scraper::{ElementRef, Node, Selector};
use url::Url;

use crate::models::{ArchiveBook, ArchiveBookDetails};

// ──────────────────────────────────────────────────────────────────
// Models (FRB entry points live in lib.rs)
// ──────────────────────────────────────────────────────────────────


// ──────────────────────────────────────────────────────────────────
// Pure helpers
// ──────────────────────────────────────────────────────────────────

/// Removes emoji/icon noise and collapses whitespace.
/// Mirrors `cleanText`.
pub(crate) fn clean_text(text: &str) -> String {
    // Review C1 (2026-11-20): the five per-range passes collapse
    // into one char class — same removed set, one scan. The
    // magnifier glyph (U+1F50D) sits inside the 1F300-1F9FF
    // block, so the old explicit replace was already dead code.
    static EMOJI: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static WS: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let emoji = EMOJI.get_or_init(|| {
        regex::Regex::new(
            r"[\u{1F300}-\u{1F9FF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}\u{1F600}-\u{1F64F}\u{1F680}-\u{1F6FF}]",
        )
        .unwrap()
    });
    let ws = WS.get_or_init(|| regex::Regex::new(r"\s+").unwrap());
    let out = emoji.replace_all(text, "");
    ws.replace_all(&out, " ").trim().to_string()
}

/// Detects the book format from the info line (word-boundary match),
/// defaulting to `epub`. Mirrors `formatFromInfo`.
pub(crate) fn format_from_info(info: Option<&str>) -> String {
    const KNOWN: [&str; 14] = [
        "pdf", "epub", "mobi", "azw3", "fb2", "djvu", "cbz", "cbr", "txt",
        "rtf", "doc", "docx", "lit", "chm",
    ];
    static MATCHERS: std::sync::OnceLock<Vec<(String, regex::Regex)>> =
        std::sync::OnceLock::new();
    let matchers = MATCHERS.get_or_init(|| {
        KNOWN
            .iter()
            .map(|f| {
                (
                    f.to_string(),
                    regex::Regex::new(&format!(r"\b{}\b", f)).unwrap(),
                )
            })
            .collect()
    });
    let lower = info.unwrap_or("").to_lowercase();
    for (format, re) in matchers {
        if re.is_match(&lower) {
            return format.clone();
        }
    }
    "epub".to_string()
}

/// Returns the md5 segment from a path or URL. Mirrors `md5FromLink`
/// (Dart Uri.pathSegments — works for relative paths too).
pub(crate) fn md5_from_link(url_or_path: &str) -> String {
    // Strip query/fragment, then split into path segments.
    let path = url_or_path.split(['?', '#']).next().unwrap_or(url_or_path);
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    if let Some(pos) = segments.iter().position(|s| *s == "md5") {
        if pos + 1 < segments.len() {
            return segments[pos + 1].to_string();
        }
    }
    segments.last().map(|s| s.to_string()).unwrap_or_default()
}

/// Text as a browser renders it: script/style contents are removed.
/// Mirrors `visibleText`.
pub(crate) fn visible_text(element: Option<&ElementRef>) -> String {
    let el = match element {
        Some(e) => e,
        None => return String::new(),
    };
    fn collect(node: ego_tree::NodeRef<'_, Node>, out: &mut String) {
        match node.value() {
            Node::Element(e) => {
                let local = e.name.local.as_ref();
                if local == "script" || local == "style" {
                    return; // skip subtree
                }
                for child in node.children() {
                    collect(child, out);
                }
            }
            Node::Text(t) => out.push_str(t.as_ref()),
            _ => {}
        }
    }
    let mut out = String::new();
    for child in el.children() {
        collect(child, &mut out);
    }
    out.trim().to_string()
}

/// Absolute URL resolution against a base (RFC-3986 join, matching
/// Dart's `Uri.parse(base).resolve(href)`).
pub(crate) fn resolve_url(base_url: &str, href: &str) -> String {
    if href.starts_with("http://") || href.starts_with("https://") {
        return href.to_string();
    }
    let base = if base_url.ends_with('/') {
        base_url.to_string()
    } else {
        format!("{}/", base_url)
    };
    match Url::parse(&base).and_then(|u| u.join(href)) {
        Ok(joined) => joined.to_string(),
        Err(_) => href.to_string(),
    }
}

/// Resolve [href] against the full page URL. Mirrors `resolveRelative`.
pub(crate) fn resolve_relative(href: &str, page_url: &str) -> String {
    if href.starts_with("http://") || href.starts_with("https://") {
        return href.to_string();
    }
    match Url::parse(page_url).and_then(|u| u.join(href)) {
        Ok(joined) => joined.to_string(),
        Err(_) => href.to_string(),
    }
}

/// True when a response is a bot-protection interstitial rather than
/// the requested page. Mirrors `isChallengeResponse`.
pub(crate) fn is_challenge_response(
    status_code: i64,
    body: &str,
    cf_mitigated: Option<&str>,
) -> bool {
    if cf_mitigated.map(|s| s.to_lowercase()) == Some("challenge".to_string()) {
        return true;
    }
    let lower = body.to_lowercase();
    if lower.is_empty() {
        return false;
    }
    static TITLE_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let title_re =
        TITLE_RE.get_or_init(|| regex::Regex::new(r"<title[^>]*>([^<]*)</title>").unwrap());
    let title = title_re
        .captures(&lower)
        .and_then(|m| m.get(1))
        .map(|m| m.as_str().trim().to_string())
        .unwrap_or_default();

    const CHALLENGE_TITLES: [&str; 4] = [
        "just a moment",
        "ddos-guard",
        "checking your browser",
        "attention required",
    ];
    if CHALLENGE_TITLES.iter().any(|t| title.starts_with(t)) {
        return true;
    }
    const HARD_MARKERS: [&str; 6] = [
        "cf-browser-verification",
        "cf-challenge-running",
        "/cdn-cgi/challenge-platform/",
        "check.ddos-guard.net",
        "data-ddg-origin",
        "__ddg",
    ];
    if HARD_MARKERS.iter().any(|m| lower.contains(m)) {
        return true;
    }
    if status_code == 403 || status_code == 503 {
        const SOFT_MARKERS: [&str; 6] = [
            "checking your browser",
            "enable javascript and cookies",
            "needs to review the security of your connection",
            "verifying you are human",
            "browser check",
            "security check",
        ];
        if SOFT_MARKERS.iter().any(|m| lower.contains(m)) {
            return true;
        }
    }
    false
}

/// True when [html] is an Anna's Archive page. Mirrors `isArchivePage`.
pub(crate) fn is_archive_page(html: &str) -> bool {
    static TITLE_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let title_re = TITLE_RE
        .get_or_init(|| regex::RegexBuilder::new(r"<title[^>]*>([^<]*)</title>")
            .case_insensitive(true)
            .build()
            .unwrap());
    let title = title_re
        .captures(html)
        .and_then(|m| m.get(1))
        .map(|m| m.as_str().to_lowercase())
        .unwrap_or_default();
    title.contains("anna") && title.contains("archive")
}

// ──────────────────────────────────────────────────────────────────
// Parsers
// ──────────────────────────────────────────────────────────────────

/// The next sibling ELEMENT of `node` (Dart's `nextElementSibling`:
/// walks over all sibling nodes, skipping non-elements).
fn sibling_after(mut node: ego_tree::NodeRef<'_, Node>) -> Option<ElementRef<'_>> {
    loop {
        node = node.next_sibling()?;
        if let Node::Element(_) = node.value() {
            return ElementRef::wrap(node);
        }
    }
}

/// Parses a search results page, including the `/md5/` link fallback.
/// Mirrors `parseSearchResults`.
pub(crate) fn parse_search_results(
    html: &str,
    base_url: &str,
    file_type: &str,
) -> Vec<ArchiveBook> {
    let document = scraper::Html::parse_document(html);
    let container_sel = sel!("div.flex.pt-3.pb-3.border-b");
    let md5_link_sel = sel!(r#"a[href*="/md5/"]"#);

    let mut containers: Vec<ElementRef> =
        document.select(&container_sel).collect();

    if containers.is_empty() {
        let md5_links: Vec<ElementRef> = document.select(&md5_link_sel).collect();
        if !md5_links.is_empty() {
            // Several links can live in one container (cover + title);
            // dedupe by NodeId, matching Dart's Set-by-identity.
            let mut seen: HashSet<ego_tree::NodeId> = HashSet::new();
            let mut found: Vec<ElementRef> = Vec::new();
            for link in md5_links {
                let mut node = (*link);
                loop {
                    match node.parent() {
                        Some(p) => node = p,
                        None => break,
                    }
                    match node.value() {
                        Node::Element(e) if e.name.local.as_ref() == "div" => {
                            if seen.insert(node.id()) {
                                if let Some(el) = ElementRef::wrap(node) {
                                    found.push(el);
                                }
                            }
                            break;
                        }
                        _ => continue,
                    }
                }
            }
            containers = found;
        }
    }

    let main_link_sel = sel!(r"a.line-clamp-\[3\].js-vim-focus");
    let thumb_sel = sel!(r#"a[href*="/md5/"] img"#);
    let info_sel = sel!("div.text-gray-800");

    let mut books = Vec::new();
    for container in containers {
        let main_link = container.select(&main_link_sel).next();
        let md5_link = container.select(&md5_link_sel).next();
        let link_element = main_link.or(md5_link);
        let link_element = match link_element {
            Some(e) => e,
            None => continue,
        };
        let thumbnail_element = container.select(&thumb_sel).next();

        let href = match link_element.attr("href") {
            Some(h) => h.to_string(),
            None => continue,
        };

        let title = clean_text(&link_element.text().collect::<String>().trim());
        let md5 = md5_from_link(&href);
        let thumbnail = thumbnail_element.and_then(|t| t.attr("src").map(|s| s.to_string()));

        // Author and publisher are the two `/search?q=` links after the
        // title link, in document order (nextElementSibling walks over
        // ALL sibling nodes, skipping non-elements). The helper is a
        // module-level fn — closure lifetime inference cannot tie the
        // NodeRef and ElementRef lifetimes here.
        let author_element = sibling_after((*link_element)).filter(|e| {
            e.attr("href")
                .map(|h| h.starts_with("/search?q="))
                .unwrap_or(false)
        });
        let publisher_element = author_element
            .and_then(|a| sibling_after((*a)))
            .filter(|e| {
                e.attr("href")
                    .map(|h| h.starts_with("/search?q="))
                    .unwrap_or(false)
            });

        let author_clean = author_element.map(|e| {
            let raw = e.text().collect::<String>().trim().to_string();
            if raw.contains("icon-") {
                // Skip the first whitespace-separated token (the icon).
                let parts: Vec<&str> = raw.split(' ').collect();
                clean_text(parts.iter().skip(1).copied().collect::<Vec<_>>().join(" ").trim())
            } else {
                clean_text(&raw)
            }
        });
        let publisher_clean = publisher_element
            .map(|e| clean_text(&e.text().collect::<String>().trim()));

        let info = visible_text(container.select(&info_sel).next().as_ref());

        let matches_type = file_type.is_empty()
            || info.to_lowercase().contains(&file_type.to_lowercase());
        if !matches_type {
            continue;
        }

        books.push(ArchiveBook {
            title,
            author: match author_clean {
                Some(ref a) if a.is_empty() => Some("unknown".to_string()),
                other => other,
            },
            thumbnail,
            link: resolve_url(base_url, &href),
            md5,
            publisher: match publisher_clean {
                Some(ref p) if p.is_empty() => Some("unknown".to_string()),
                other => other,
            },
            info: Some(info),
        });
    }
    books
}

/// Parses one `/md5/` detail page. Returns None when the page has no
/// book record ("not found" vs network error). Mirrors `parseBookDetails`.
pub(crate) fn parse_book_details(
    html: &str,
    url: &str,
    base_url: &str,
) -> Option<ArchiveBookDetails> {
    let document = scraper::Html::parse_document(html);
    let main = document.select(&sel!("div.main-inner")).next()?;
    let title_element = main
        .select(&sel!("div.font-semibold.text-2xl"))
        .next()?;

    let slow_links: Vec<ElementRef> = main
        .select(&sel!(r#"ul.list-inside a[href*="/slow_download/"]"#))
        .collect();
    let slow_download = slow_links
        .first()
        .and_then(|l| l.attr("href"))
        .filter(|h| !h.is_empty())
        .map(|h| resolve_url(base_url, h));

    let author_element = main
        .select(&sel!(r#"a[href^="/search?q="].text-base"#))
        .next();
    let publisher_element = author_element
        .and_then(|a| sibling_after((*a)))
        .filter(|e| {
            e.attr("href")
                .map(|h| h.starts_with("/search?q="))
                .unwrap_or(false)
        });

    let thumbnail_element = main
        .select(&sel!(r#"div[id^="list_cover_"] img"#))
        .next();

    let description_label = main
        .select(
            &sel!(
                "div.js-md5-top-box-description div.text-xs.text-gray-500.uppercase"
            ),
        )
        .next();
    let description_element = if description_label
        .map(|l| l.text().collect::<String>().trim().to_lowercase())
        .as_deref()
        == Some("description")
    {
        description_label.and_then(|l| sibling_after((*l)))
    } else {
        None
    };

    let title = clean_text(&title_element.text().collect::<String>().trim());
    let author = clean_text(
        &author_element
            .map(|e| e.text().collect::<String>().trim().to_string())
            .unwrap_or_else(|| "unknown".to_string()),
    );
    let publisher = clean_text(
        &publisher_element
            .map(|e| e.text().collect::<String>().trim().to_string())
            .unwrap_or_else(|| "unknown".to_string()),
    );
    let info = visible_text(main.select(&sel!("div.text-gray-800")).next().as_ref());

    Some(ArchiveBookDetails {
        title,
        author: Some(author),
        thumbnail: thumbnail_element.and_then(|t| t.attr("src").map(|s| s.to_string())),
        publisher: Some(publisher),
        info: Some(info),
        link: url.to_string(),
        md5: md5_from_link(url),
        description: Some(visible_text(description_element.as_ref())),
        slow_download_url: slow_download,
    })
}

/// Extracts the direct download link from a `slow_download` page.
/// Mirrors `extractSlowDownloadLink`.
pub(crate) fn extract_slow_download_link(html: &str, page_url: &str) -> Option<String> {
    let document = scraper::Html::parse_document(html);
    // Class-combining selector first; the exact attribute match stays
    // as a fallback.
    let paragraph = document
        .select(&sel!("p.mb-4.text-xl.font-bold"))
        .next()
        .or_else(|| {
            document
                .select(&sel!(r#"p[class="mb-4 text-xl font-bold"]"#))
                .next()
        })?;
    let href = paragraph
        .select(&sel!("a"))
        .next()?
        .attr("href")?
        .to_string();
    if href.is_empty() {
        return None;
    }
    if page_url.is_empty() {
        return Some(href);
    }
    Some(resolve_relative(&href, page_url))
}

/// Percent-encode a query component exactly like Dart's
/// `Uri.encodeQueryComponent`: space → `+`, unreserved
/// [A-Za-z0-9-_.!~*'()] pass through, everything else %-encodes UTF-8.
fn encode_query_component(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for byte in s.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.'
            | b'!' | b'~' | b'*' | b'\'' | b'(' | b')' => {
                out.push(byte as char);
            }
            b' ' => out.push('+'),
            other => out.push_str(&format!("%{:02X}", other)),
        }
    }
    out
}

/// Builds a `/search` URL. Mirrors the app's historical `urlEncoder`:
/// author/publisher become field-scoped terms inside `q`, filters ride
/// the documented query parameters, and page 1 omits `page`.
/// Mirrors `buildSearchUrl`.
pub(crate) fn build_search_url(
    base_url: &str,
    query: &str,
    content: &str,
    sort: &str,
    file_type: &str,
    language: &str,
    year: &str,
    year_from: Option<&str>,
    year_to: Option<&str>,
    author: &str,
    publisher: &str,
    enable_filters: Option<bool>,
    page: i64,
) -> String {
    let mut field_terms = String::new();
    let author_t = author.trim();
    if !author_t.is_empty() {
        field_terms.push_str(&format!(
            "author:%22{}%22 ",
            encode_query_component(author_t)
        ));
    }
    let publisher_t = publisher.trim();
    if !publisher_t.is_empty() {
        field_terms.push_str(&format!(
            "publisher:%22{}%22 ",
            encode_query_component(publisher_t)
        ));
    }
    let encoded_query = format!(
        "{}{}",
        field_terms,
        encode_query_component(query.trim())
    );

    let has_year_range = year_from.map(|s| !s.is_empty()).unwrap_or(false)
        || year_to.map(|s| !s.is_empty()).unwrap_or(false);
    let filters = enable_filters.unwrap_or(
        !content.is_empty()
            || !sort.is_empty()
            || !file_type.is_empty()
            || !language.is_empty()
            || !year.is_empty()
            || has_year_range,
    );

    let page_param = if page > 1 { format!("&page={}", page) } else { String::new() };
    if !filters {
        return format!("{}/search?q={}{}", base_url, encoded_query, page_param);
    }

    let mut url = format!("{}/search?index=&sort={}", base_url, sort);
    if !language.is_empty() {
        url.push_str(&format!("&lang={}", language));
    }
    url.push_str("&display=");
    url.push_str(&format!("&q={}", encoded_query));
    if !content.is_empty() {
        url.push_str(&format!("&content={}", content));
    }
    if !file_type.is_empty() {
        url.push_str(&format!("&ext={}", file_type));
    }
    if !year.is_empty() {
        if year == "Before 1980" {
            url.push_str("&year_end=1979");
        } else if year.contains('-') {
            let parts: Vec<&str> = year.split('-').collect();
            if parts.len() == 2 {
                url.push_str(&format!(
                    "&year_from={}&year_end={}",
                    parts[0].trim(),
                    parts[1].trim()
                ));
            }
        } else {
            url.push_str(&format!("&year={}", year));
        }
    }
    if let Some(yf) = year_from {
        if !yf.is_empty() {
            url.push_str(&format!("&year_from={}", yf.trim()));
        }
    }
    if let Some(yt) = year_to {
        if !yt.is_empty() {
            url.push_str(&format!("&year_end={}", yt.trim()));
        }
    }
    format!("{}{}", url, page_param)
}

// ──────────────────────────────────────────────────────────────────
// Tests — differential baseline from test/parsers/anna_parsing_test.dart
// ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    const BASE: &str = "https://annas-archive.org";

    const SEARCH_HTML: &str = r#"<div class="flex pt-3 pb-3 border-b">
<a class="line-clamp-[3] js-vim-focus" href="/md5/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">三体</a>
<a href="/search?q=author%3A%E5%88%98%E6%85%88%E6%AC%A3">刘慈欣</a>
<a href="/search?q=publisher%3A%E9%87%8D%E5%BA%86%E5%87%BA%E7%89%88%E7%A4%BE">重庆出版社</a>
<div class="text-gray-800">Chinese [zh] · EPUB · 3.12 MB</div>
<a href="/md5/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"><img src="https://covers.example.com/1.jpg"></a>
</div>
<div class="flex pt-3 pb-3 border-b">
<a class="line-clamp-[3] js-vim-focus" href="/md5/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb">Second Book</a>
<a href="/search?q=author%3A...">Author B</a>
<a href="/search?q=publisher%3A...">Publisher B</a>
<div class="text-gray-800">English [en] · PDF · 2.06 MB</div>
</div>"#;

    const DETAIL_HTML: &str = r#"<div class="main-inner">
<div class="font-semibold text-2xl">三体</div>
<a class="text-base" href="/search?q=author%3A...">刘慈欣</a>
<a href="/search?q=publisher%3A...">重庆出版社</a>
<div id="list_cover_1"><img src="https://covers.example.com/1.jpg"></div>
<div class="text-gray-800">Chinese [zh] · EPUB · 3.12 MB</div>
<div class="js-md5-top-box-description">
<div class="text-xs text-gray-500 uppercase">Description</div>
<div>一本关于三体的书。</div>
</div>
<ul class="list-inside"><li><a href="/slow_download/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">Slow download</a></li></ul>
</div>"#;

    #[test]
    fn clean_text_removes_emoji_and_folds_whitespace() {
        assert_eq!(clean_text("  Hello 🌍  world 🔍 "), "Hello world");
        assert_eq!(clean_text("a\n\n  b"), "a b");
    }

    #[test]
    fn format_from_info_detects_and_defaults() {
        assert_eq!(format_from_info(Some("English [en] pdf 2 MB")), "pdf");
        assert_eq!(format_from_info(Some("cbr 10 MB")), "cbr");
        assert_eq!(format_from_info(Some("cbz 10 MB")), "cbz");
        assert_eq!(format_from_info(Some("EPUB 3 MB")), "epub");
        assert_eq!(format_from_info(None), "epub");
        assert_eq!(format_from_info(Some("")), "epub");
    }

    #[test]
    fn md5_from_link_takes_segment_after_md5() {
        assert_eq!(md5_from_link("/md5/abc123/"), "abc123");
        assert_eq!(
            md5_from_link("https://annas-archive.org/md5/def456"),
            "def456"
        );
        assert_eq!(md5_from_link(""), "");
    }

    #[test]
    fn parse_search_results_parses_all_fields() {
        let books = parse_search_results(SEARCH_HTML, BASE, "");
        assert_eq!(books.len(), 2);

        let first = &books[0];
        assert_eq!(first.title, "三体");
        assert_eq!(first.author.as_deref(), Some("刘慈欣"));
        assert_eq!(first.publisher.as_deref(), Some("重庆出版社"));
        assert_eq!(first.md5, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        assert_eq!(first.link, format!("{BASE}/md5/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
        assert_eq!(first.thumbnail.as_deref(), Some("https://covers.example.com/1.jpg"));
        assert_eq!(first.info.as_deref(), Some("Chinese [zh] · EPUB · 3.12 MB"));
        assert_eq!(format_from_info(first.info.as_deref()), "epub");

        assert_eq!(books[1].title, "Second Book");
        assert_eq!(format_from_info(books[1].info.as_deref()), "pdf");
        assert_eq!(books[1].thumbnail, None);
    }

    #[test]
    fn file_type_filter_drops_non_matching() {
        let books = parse_search_results(SEARCH_HTML, BASE, "pdf");
        assert_eq!(books.len(), 1);
        assert_eq!(books[0].title, "Second Book");
    }

    #[test]
    fn md5_link_fallback_when_containers_absent() {
        let html = r#"<div class="results">
<div><a href="/md5/cccccccccccccccccccccccccccccccc">Fallback Book</a></div>
</div>"#;
        let books = parse_search_results(html, BASE, "");
        assert_eq!(books.len(), 1);
        assert_eq!(books[0].title, "Fallback Book");
        assert_eq!(books[0].md5, "cccccccccccccccccccccccccccccccc");
        assert_eq!(books[0].author, None);
    }

    #[test]
    fn page_with_no_results_parses_empty() {
        assert!(parse_search_results("<html><body>no results</body></html>", BASE, "").is_empty());
    }

    #[test]
    fn parse_book_details_parses_all_fields() {
        let details = parse_book_details(
            DETAIL_HTML,
            &format!("{BASE}/md5/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/三体"),
            BASE,
        );
        let d = details.expect("detail page must parse");
        assert_eq!(d.title, "三体");
        assert_eq!(d.author.as_deref(), Some("刘慈欣"));
        assert_eq!(d.publisher.as_deref(), Some("重庆出版社"));
        assert_eq!(d.md5, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        assert_eq!(d.thumbnail.as_deref(), Some("https://covers.example.com/1.jpg"));
        assert_eq!(d.description.as_deref(), Some("一本关于三体的书。"));
        assert_eq!(
            d.slow_download_url.as_deref(),
            Some(&format!("{BASE}/slow_download/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")[..])
        );
    }

    #[test]
    fn book_details_null_without_record() {
        assert!(parse_book_details(
            "<html><body>not a book page</body></html>",
            &format!("{BASE}/md5/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/x"),
            BASE,
        )
        .is_none());
        assert!(parse_book_details(
            "<div class=\"main-inner\"><p>no title here</p></div>",
            &format!("{BASE}/md5/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/x"),
            BASE,
        )
        .is_none());
    }

    #[test]
    fn missing_description_degrades_to_empty_string() {
        let html = r#"<div class="main-inner">
<div class="font-semibold text-2xl">T</div>
</div>"#;
        let details = parse_book_details(
            html,
            &format!("{BASE}/md5/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/T"),
            BASE,
        )
        .expect("must parse");
        assert_eq!(details.description.as_deref(), Some(""));
        assert_eq!(details.slow_download_url, None);
    }

    #[test]
    fn challenge_response_recognition() {
        assert!(is_challenge_response(
            403,
            "checking your browser before accessing the site",
            None
        ));
        assert!(is_challenge_response(200, "<title>Just a moment...</title>", None));
        assert!(is_challenge_response(200, "plain page", Some("challenge")));
        assert!(!is_challenge_response(
            200,
            "<title>Anna's Archive</title>results",
            None
        ));
    }

    #[test]
    fn archive_page_title_check() {
        assert!(is_archive_page("<title>Anna's Archive</title>"));
        assert!(!is_archive_page("<title>Google</title>"));
    }

    #[test]
    fn slow_download_link_extraction() {
        let html = r#"<p class="mb-4 text-xl font-bold"><a href="https://dl.example.com/f.epub">Download</a></p>"#;
        assert_eq!(
            extract_slow_download_link(html, ""),
            Some("https://dl.example.com/f.epub".to_string())
        );
        assert_eq!(extract_slow_download_link("<p>no link</p>", ""), None);
    }

    #[test]
    fn build_search_url_plain_omits_page_1() {
        assert_eq!(
            build_search_url(BASE, "harry potter", "", "", "", "", "", None, None, "", "", None, 1),
            format!("{BASE}/search?q=harry+potter")
        );
    }

    #[test]
    fn build_search_url_filters_and_page_2() {
        let url = build_search_url(
            BASE, "x", "book_nonfiction", "newest", "", "", "", None, None,
            "", "", None, 2,
        );
        assert!(url.contains("sort=newest"));
        assert!(url.contains("content=book_nonfiction"));
        assert!(url.contains("&page=2"));
    }

    #[test]
    fn resolve_url_absolute_and_relative() {
        assert_eq!(resolve_url(BASE, "/md5/abc"), format!("{BASE}/md5/abc"));
        assert_eq!(
            resolve_url(BASE, "https://other.example.com/md5/abc"),
            "https://other.example.com/md5/abc"
        );
    }
}