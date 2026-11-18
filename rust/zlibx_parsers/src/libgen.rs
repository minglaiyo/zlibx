//! Library Genesis parsers — Rust port of
//! `lib/services/external_search.dart` (`LibgenProvider.parseResults`
//! and its row helpers) and `lib/services/libgen_service.dart`
//! (`parseAdsPage` / `parseAdsCover` / `_labeledFields` / `_formatFrom`).
//!
//! Handles both table layouts in the wild: the libgen.li/vg
//! "tablelibgen" table and the older table.c.

use scraper::{ElementRef, Selector};

use crate::models::{LibgenBookData, LibgenBookInfoData};

// ──────────────────────────────────────────────────────────────────
// parseResults (search results, both layouts)
// ──────────────────────────────────────────────────────────────────

/// Parses a libgen results page. Mirrors
/// `LibgenProvider.parseResults(String html, String baseUrl)`.
pub(crate) fn parse_results(html: &str, base_url: &str) -> Vec<LibgenBookData> {
    let document = scraper::Html::parse_document(html);

    // The libgen.li/vg family marks its results table with an id. The
    // older libgen layout uses a table.c; rows live in its tbody.
    let li_sel = Selector::parse("#tablelibgen tr").unwrap();
    let td_sel = Selector::parse("td").unwrap();
    let li_rows: Vec<ElementRef> = document.select(&li_sel).collect();
    let li_layout = li_rows.iter().any(|row| {
        row.select(&td_sel).count() >= 9
    });
    if li_layout {
        return li_rows
            .iter()
            .filter_map(|row| li_row_to_book(row, base_url))
            .collect();
    }

    let legacy_sel = Selector::parse("table.c tbody tr").unwrap();
    document
        .select(&legacy_sel)
        .filter_map(|row| legacy_row_to_book(&row, base_url))
        .collect()
}

fn cells_of<'a>(row: &ElementRef<'a>) -> Vec<ElementRef<'a>> {
    let td_sel = Selector::parse("td").unwrap();
    row.select(&td_sel).collect()
}

fn cell_text(cells: &[ElementRef], i: usize) -> String {
    cells
        .get(i)
        .map(|c| c.text().collect::<String>().trim().to_string())
        .unwrap_or_default()
}

/// libgen.li-family layout. Mirrors `_liRowToBook`.
fn li_row_to_book(row: &ElementRef, base_url: &str) -> Option<LibgenBookData> {
    let cells = cells_of(row);
    // [title(+links), author, series, year, language, pages, size,
    //  extension, mirrors].
    if cells.len() < 9 {
        return None;
    }

    let title_cell = cells[0];
    // The first link points at series.php - the work's own title. The
    // edition links below describe specific editions and would drown
    // the real title out.
    let series_sel = Selector::parse(r#"a[href*="series.php"], a[href*="index.php?"]"#).unwrap();
    let a_sel = Selector::parse("a").unwrap();
    let series_link = title_cell.select(&series_sel).next();
    let title = series_link
        .or_else(|| title_cell.select(&a_sel).next())
        .map(|e| e.text().collect::<String>().trim().to_string())
        .or_else(|| Some(title_cell.text().collect::<String>().trim().to_string()))
        .filter(|t| !t.is_empty())?;

    // An md5 download link from the mirrors cell, if present. Fall
    // back to the edition link's id - unique per book either way.
    let md5_link_sel = Selector::parse(r#"a[href*="md5="]"#).unwrap();
    let md5_links: Vec<String> = cells[8]
        .select(&md5_link_sel)
        .filter_map(|a| a.attr("href").map(|h| h.to_string()))
        .collect();
    let id_sel = Selector::parse(r#"a[href*="id="]"#).unwrap();
    static ID_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let id_re = ID_RE.get_or_init(|| regex::Regex::new(r"id=(\d+)").unwrap());
    let id_matches: Vec<String> = cells[0]
        .select(&id_sel)
        .filter_map(|a| {
            a.attr("href")
                .and_then(|h| id_re.captures(h))
                .and_then(|m| m.get(1))
                .map(|g| g.as_str().to_string())
        })
        .collect();
    let md5 = md5_from_hrefs(&md5_links).or_else(|| id_matches.first().cloned());

    let cell = |i: usize| cell_text(&cells, i);
    static WS: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let ws = WS.get_or_init(|| regex::Regex::new(r"\s+").unwrap());
    let info = [
        Some(cell(4)), // language
        {
            let ext = cell(7);
            if ext.is_empty() { None } else { Some(ext.to_uppercase()) }
        },
        {
            let size = cell(6);
            if size.is_empty() { None } else { Some(ws.replace_all(&size, " ").to_string()) }
        },
        Some(cell(3)), // year
    ]
    .into_iter()
    .flatten()
    .filter(|s| !s.is_empty())
    .collect::<Vec<_>>()
    .join(", ");

    let fallback_href = title_cell
        .select(&a_sel)
        .next()
        .and_then(|a| a.attr("href"))
        .unwrap_or("")
        .to_string();
    let link = match &md5 {
        Some(m) => format!("{}/ads.php?md5={}", base_url, m),
        None => {
            if fallback_href.starts_with("http") {
                fallback_href.clone()
            } else {
                format!("{}{}", base_url, fallback_href)
            }
        }
    };

    let author = {
        let a = cell(1);
        if a.is_empty() { "Unknown".to_string() } else { a }
    };
    let publisher = {
        let p = cell(2);
        if p.is_empty() { None } else { Some(p) }
    };
    let md5 = md5.unwrap_or_else(|| title.clone());
    Some(LibgenBookData {
        title,
        author: Some(author),
        thumbnail: None,
        link,
        md5,
        publisher,
        info: if info.is_empty() { None } else { Some(info) },
    })
}

/// Older libgen layout. Mirrors `_legacyRowToBook`.
fn legacy_row_to_book(row: &ElementRef, base_url: &str) -> Option<LibgenBookData> {
    let cells = cells_of(row);
    // [id, author, title(+link), publisher, year, pages, language,
    //  size, extension, ...mirror links].
    if cells.len() < 5 {
        return None;
    }

    let title_cell = cells[2];
    let title_link = title_cell.select(&Selector::parse("a").unwrap()).next();
    let href = title_link.and_then(|a| a.attr("href")).map(|h| h.to_string())?;
    let title = title_link
        .map(|a| a.text().collect::<String>())
        .unwrap_or_else(|| title_cell.text().collect::<String>())
        .trim()
        .to_string();
    if title.is_empty() {
        return None;
    }

    let cell = |i: usize| cell_text(&cells, i);
    let info = [
        Some(cell(6)), // language
        {
            let ext = cell(8);
            if ext.is_empty() { None } else { Some(ext.to_uppercase()) }
        },
        Some(cell(7)), // size
        Some(cell(4)), // year
    ]
    .into_iter()
    .flatten()
    .filter(|s| !s.is_empty())
    .collect::<Vec<_>>()
    .join(", ");

    let link = if href.starts_with("http") {
        href.clone()
    } else {
        format!("{}{}", base_url, href)
    };

    let author = {
        let a = cell(1);
        if a.is_empty() { "Unknown".to_string() } else { a }
    };
    let publisher = {
        let p = cell(3);
        if p.is_empty() { None } else { Some(p) }
    };
    let md5 =
        md5_from_hrefs(std::slice::from_ref(&href)).unwrap_or_else(|| title.clone());
    Some(LibgenBookData {
        title,
        author: Some(author),
        thumbnail: None,
        link,
        md5,
        publisher,
        info: if info.is_empty() { None } else { Some(info) },
    })
}

/// `[?&]md5=<32hex>` from the first href that carries one.
/// Mirrors `_md5FromHref`.
fn md5_from_hrefs(hrefs: &[String]) -> Option<String> {
    static MD5_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let re = MD5_RE.get_or_init(|| regex::Regex::new(r"[?&]md5=([0-9a-fA-F]{32})").unwrap());
    for href in hrefs {
        if let Some(m) = re.captures(href) {
            if let Some(g) = m.get(1) {
                return Some(g.as_str().to_string());
            }
        }
    }
    None
}

// ──────────────────────────────────────────────────────────────────
// ads.php page (book info)
// ──────────────────────────────────────────────────────────────────

/// Extracts just the cover URL from an `ads.php` page.
/// Mirrors `parseAdsCover` (static).
pub(crate) fn parse_ads_cover(html: &str, base_url: &str) -> Option<String> {
    let document = scraper::Html::parse_document(html);
    let img = document
        .select(&Selector::parse("table#main img").unwrap())
        .next()?;
    let src = img.attr("src")?;
    if src.is_empty() {
        return None;
    }
    Some(
        if src.starts_with("http") {
            src.to_string()
        } else {
            format!("{}{}", base_url, src)
        },
    )
}

/// Splits "Title: A Series: B Author(s): C" on known labels. Value of
/// a label runs until the next label or end of text.
/// Mirrors `_labeledFields` (a LinkedHashMap in Dart — iteration order
/// does not matter here because lookups are by key).
fn labeled_fields(text: &str) -> std::collections::HashMap<String, String> {
    static WS: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let ws = WS.get_or_init(|| regex::Regex::new(r"\s+").unwrap());
    // Dart's _collapseWhitespace folds AND trims.
    let collapse_trim =
        |s: &str| -> String { ws.replace_all(s, " ").trim().to_string() };
    const LABELS: [&str; 10] = [
        "Title:",
        "Series:",
        "Author(s):",
        "Author:",
        "Publisher:",
        "Year:",
        "ISBN:",
        "Language:",
        "Size:",
        "Pages:",
    ];
    let mut fields = std::collections::HashMap::new();
    for label in LABELS {
        let start = match text.find(label) {
            Some(i) => i,
            None => continue,
        };
        let value_start = start + label.len();
        let mut end = text.len();
        for other in LABELS {
            if let Some(idx) = text[value_start..].find(other) {
                let idx = value_start + idx;
                if idx < end {
                    end = idx;
                }
            }
        }
        fields.insert(
            label.trim_end_matches(':').to_string(),
            collapse_trim(&text[value_start..end]),
        );
    }
    fields
}

/// File format from the get.php link or page; defaults to `epub`.
/// Only a real `.<ext>` token counts. Mirrors `_formatFrom`.
/// NOTE: Dart's pattern uses a lookahead `(?=["<\s?])` after the
/// second branch; the `regex` crate has no look-around, so the
/// boundary character is consumed by a non-capturing group instead
/// (`(?:[\"<\s?]|$)` — the `$` arm is a behavior superset at end-of-
/// string, which no real page hits).
fn format_from(html: &str, url: &str) -> String {
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let re = RE.get_or_init(|| {
        regex::RegexBuilder::new(
            r#"[?&](?:ext|format)=\w*?(epub|pdf|mobi|azw3?|cbr|cbz|djvu)|\.(epub|pdf|mobi|azw3?|cbr|cbz|djvu)(?:["<\s?]|$)"#,
        )
        .case_insensitive(true)
        .build()
        .unwrap()
    });
    for source in [url, html] {
        if let Some(m) = re.captures(source) {
            let ext = m.get(1).or(m.get(2));
            if let Some(e) = ext {
                return e.as_str().to_lowercase();
            }
        }
    }
    "epub".to_string()
}

fn absolute(href: &str, base_url: &str) -> String {
    if href.starts_with("http") {
        return href.to_string();
    }
    if href.starts_with('/') {
        format!("{}{}", base_url, href)
    } else {
        format!("{}/{}", base_url, href)
    }
}

/// Parses a libgen `ads.php` page. Returns None on markup this parser
/// does not recognize - never throws. Mirrors `parseAdsPage`.
/// NOTE: Dart's version logs via `_logger` on failure; the Rust port
/// returns None silently (the Dart call site can log around the hook).
pub(crate) fn parse_ads_page(
    html: &str,
    base_url: &str,
    url: &str,
) -> Option<LibgenBookInfoData> {
    let document = scraper::Html::parse_document(html);

    let get_href = document
        .select(&Selector::parse(r#"a[href*="get.php?md5="]"#).unwrap())
        .next()?
        .attr("href")?
        .to_string();

    let main_table = document
        .select(&Selector::parse("table#main").unwrap())
        .next()?;

    // The metadata row: "Title: ... <br> Author(s): ... <br> ..." —
    // fields are split on their labels.
    static WS: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let ws = WS.get_or_init(|| regex::Regex::new(r"\s+").unwrap());
    let tr_sel = Selector::parse("tr").unwrap();
    let mut row_text = String::new();
    for row in main_table.select(&tr_sel) {
        let text = row.text().collect::<String>();
        if text.contains("Title:") && text.contains("Author") {
            row_text = ws.replace_all(&text, " ").trim().to_string();
            break;
        }
    }
    if row_text.is_empty() {
        return None;
    }

    let fields = labeled_fields(&row_text);
    let title = match fields.get("Title").filter(|t| !t.is_empty()) {
        Some(t) => t.clone(),
        None => return None,
    };

    static MD5_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let md5_re = MD5_RE.get_or_init(|| regex::Regex::new(r"[?&]md5=([0-9a-fA-F]{32})").unwrap());
    let md5 = md5_re
        .captures(url)
        .and_then(|m| m.get(1))
        .or_else(|| md5_re.captures(&get_href).and_then(|m| m.get(1)))
        .map(|g| g.as_str().to_string())
        .unwrap_or_else(|| title.clone());

    let src = main_table
        .select(&Selector::parse("img").unwrap())
        .next()
        .and_then(|img| img.attr("src"))
        .map(|s| s.to_string());
    let thumbnail = src
        .filter(|s| !s.is_empty())
        .map(|s| absolute(&s, base_url));

    let series = fields.get("Series");
    let year = fields.get("Year");
    let publisher = [
        fields.get("Publisher").filter(|p| !p.is_empty()).cloned(),
        year.filter(|y| !y.is_empty()).cloned(),
        series
            .filter(|s| !s.is_empty())
            .map(|s| format!("Series: {}", s)),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>()
    .join(", ");

    let info = fields
        .get("Language")
        .filter(|l| !l.is_empty())
        .cloned()
        .unwrap_or_default();

    Some(LibgenBookInfoData {
        title,
        author: {
            let a = fields.get("Author(s)").cloned().unwrap_or_default();
            if a.is_empty() { Some("Unknown".to_string()) } else { Some(a) }
        },
        thumbnail,
        publisher: if publisher.is_empty() {
            Some("Unknown".to_string())
        } else {
            Some(publisher)
        },
        info: if info.is_empty() { None } else { Some(info) },
        link: url.to_string(),
        md5,
        format: format_from(html, url),
        mirror: Some(absolute(&get_href, base_url)),
        description: None,
    })
}

// ──────────────────────────────────────────────────────────────────
// Tests — differential baseline from test/parsers/libgen_test.dart
// (the ads.php path; parseResults has no Dart-side fixture file, so
// it is covered by compile + the ads tests sharing the same helpers)
// ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    const ADS_HTML: &str = r#"<table id="main">
<tr><td>
Title: 资本论（全三卷）<br>Author(s): 马克思<br>Publisher: 人民出版社<br>Year: 2018<br>Language: Chinese<br>
</td></tr>
<tr><td><img src="/covers/123.jpg"></td></tr>
<tr><td><a href="get.php?md5=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&key=1">GET</a></td></tr>
</table>"#;

    #[test]
    fn ads_cover_resolves_relative() {
        assert_eq!(
            parse_ads_cover(ADS_HTML, "https://libgen.is"),
            Some("https://libgen.is/covers/123.jpg".to_string())
        );
    }

    #[test]
    fn ads_cover_keeps_absolute_and_rejects_missing() {
        let absolute = "<table id=\"main\"><tr><td><img src=\"https://cdn.example.com/c.jpg\"></td></tr></table>";
        assert_eq!(
            parse_ads_cover(absolute, "https://libgen.is"),
            Some("https://cdn.example.com/c.jpg".to_string())
        );
        assert_eq!(
            parse_ads_cover("<table id=\"main\"><tr><td>no image</td></tr></table>", "https://libgen.is"),
            None
        );
        assert_eq!(
            parse_ads_cover("<table id=\"main\"><tr><td><img src=\"\"></td></tr></table>", "https://libgen.is"),
            None
        );
        assert_eq!(parse_ads_cover("<p>no table</p>", "https://libgen.is"), None);
    }

    #[test]
    fn ads_page_parses_all_fields() {
        let info = parse_ads_page(
            ADS_HTML,
            "https://libgen.is",
            "https://libgen.is/ads.php?md5=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        )
        .expect("ads page must parse");
        assert_eq!(info.title, "资本论（全三卷）");
        assert_eq!(info.author.as_deref(), Some("马克思"));
        assert_eq!(info.md5, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        assert_eq!(
            info.mirror.as_deref(),
            Some("https://libgen.is/get.php?md5=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&key=1")
        );
        assert_eq!(
            info.thumbnail.as_deref(),
            Some("https://libgen.is/covers/123.jpg")
        );
        assert_eq!(info.publisher.as_deref(), Some("人民出版社, 2018"));
        assert_eq!(info.info.as_deref(), Some("Chinese"));
        assert_eq!(info.format, "epub");
    }

    #[test]
    fn ads_page_null_on_unrecognized_markup() {
        assert!(parse_ads_page(
            "<table id=\"main\"><tr><td>No get link here</td></tr></table>",
            "https://libgen.is",
            "https://libgen.is/ads.php?md5=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        )
        .is_none());
        assert!(parse_ads_page(
            "<p>no table at all</p>",
            "https://libgen.is",
            "https://libgen.is/ads.php?md5=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        )
        .is_none());
        assert!(parse_ads_page(
            "<table id=\"main\"><tr><td><a href=\"get.php?md5=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\">GET</a></td></tr><tr><td>No title row</td></tr></table>",
            "https://libgen.is",
            "https://libgen.is/ads.php?md5=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        )
        .is_none());
    }
}
