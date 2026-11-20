//! Book detail page metadata parser — Rust port of
//! `vendor/olib_api_plugin/lib/src/book_detail_html.dart`.
//!
//! Rows are matched by the `property_<key>` class; when a row has no
//! such class the (localized) label text is matched instead. The IPFS
//! row's real values live in the `data-copy` attributes of its two
//! spans, NOT in the row text. The rating spans are hidden with the
//! extra class `none` for unrated books and must parse to None.

use crate::sel;
use scraper::{ElementRef, Selector};

use crate::models::BookDetailMetadata;

/// Parse the detail-page metadata rows out of a detail page's HTML.
/// Missing rows parse to `None`; empty/whitespace-only values parse to
/// `None`. A page with no `bookProperty` rows parses to an all-None
/// [`BookDetailMetadata`] (never throws).
///
/// Mirrors `parseBookDetailProperties(String html)`.
pub(crate) fn parse_book_detail_properties(html: &str) -> BookDetailMetadata {
    let doc = scraper::Html::parse_document(html);
    let book_property_sel = sel!("div.bookProperty");
    let label_sel = sel!("div.property_label");
    let value_sel = sel!("div.property_value");

    // All bookProperty rows, collected once.
    let rows: Vec<ElementRef> = doc.select(&book_property_sel).collect();

    let row_value = |row: ElementRef| -> Option<String> {
        let value_el = row.select(&value_sel).next()?;
        let text = value_el.text().collect::<String>().trim().to_string();
        if text.is_empty() {
            None
        } else {
            Some(text)
        }
    };

    let has_class = |row: &ElementRef, class: &str| -> bool {
        row.attr("class")
            .unwrap_or("")
            .split_whitespace()
            .any(|c| c == class)
    };

    // byClass: the row carrying class `property_<key>`.
    let by_class = |key: &str| -> Option<String> {
        let class = format!("property_{}", key);
        rows.iter()
            .find(|r| has_class(r, &class))
            .and_then(|r| row_value(*r))
    };

    // Label normalization: trim, lowercase, strip trailing `:` / `：`
    // (repeatedly, like Dart's while-loop).
    let normalize_label = |text: &str| -> String {
        let mut label = text.trim().to_lowercase();
        while label.ends_with(':') || label.ends_with('：') {
            label.pop();
        }
        label.trim().to_string()
    };

    let label_of = |row: &ElementRef| -> Option<String> {
        let label_el = row.select(&label_sel).next()?;
        Some(normalize_label(&label_el.text().collect::<String>()))
    };

    // byLabel: the row whose normalized label equals `label`. Rows
    // without a label element (e.g. property_language_year's bare
    // text node) are skipped.
    let row_with_label = |label: &str| -> Option<ElementRef> {
        rows.iter()
            .find(|r| label_of(r).as_deref() == Some(label))
            .copied()
    };
    let by_label = |label: &str| -> Option<String> {
        row_with_label(label).and_then(row_value)
    };

    // IPFS values come from `span[data-copy]` attributes, not row text.
    let ipfs_copies = || -> Vec<String> {
        let scope = rows
            .iter()
            .find(|r| has_class(r, "property_ipfs_cid"))
            .copied()
            .or_else(|| row_with_label("ipfs"));
        let scope = match scope {
            Some(s) => s,
            None => return Vec::new(),
        };
        let data_copy_sel = sel!("span[data-copy]");
        scope
            .select(&data_copy_sel)
            .filter_map(|span| {
                span.attr("data-copy")
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
            })
            .collect()
    };

    // Rating spans: visible text only — a `none`-classed (hidden,
    // unrated) span parses to None.
    // Review C1 (2026-11-20): the two rating selectors are
    // constants; parse each once per process, not once per page.
    static RATING_INTEREST_SEL: std::sync::OnceLock<Selector> =
        std::sync::OnceLock::new();
    static RATING_QUALITY_SEL: std::sync::OnceLock<Selector> =
        std::sync::OnceLock::new();
    let rating_score =
        |sel: &'static std::sync::OnceLock<Selector>,
         selector: &'static str|
         -> Option<String> {
            let parsed = sel.get_or_init(|| Selector::parse(selector).unwrap());
            let span = doc.select(parsed).next()?;
        if span
            .attr("class")
            .unwrap_or("")
            .split_whitespace()
            .any(|c| c == "none")
        {
            return None;
        }
        let text = span.text().collect::<String>().trim().to_string();
        if text.is_empty() {
            None
        } else {
            Some(text)
        }
    };

    let copies = ipfs_copies();
    BookDetailMetadata {
        volume: by_class("volume")
            .or_else(|| by_label("卷"))
            .or_else(|| by_label("volume")),
        isbn10: by_class("isbn_10").or_else(|| by_label("isbn 10")),
        isbn13: by_class("isbn_13").or_else(|| by_label("isbn 13")),
        ipfs_cid: copies.first().cloned(),
        ipfs_cid_blake2b: copies.get(1).cloned(),
        rating_interest: rating_score(
            &RATING_INTEREST_SEL,
            ".book-rating-interest-score",
        ),
        rating_quality: rating_score(
            &RATING_QUALITY_SEL,
            ".book-rating-quality-score",
        ),
    }
}

// ──────────────────────────────────────────────────────────────────
// Tests — differential baseline from test/parsers/book_detail_metadata_test.dart
// ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    const DETAIL_HTML: &str = r#"<html><body><div class="bookDetailsBox">
<div class="bookProperty property_categories">
  <div class="property_label">种类:</div>
  <div class="property_value"><a href="/category/153/Childrens-Books-Science-Fiction-Fantasy">Children's Books - Science Fiction &amp; Fantasy</a></div>
</div>
<div class="bookProperty property_content_type">
  <div class="property_label">内容类型:</div>
  <div class="property_value">书籍</div>
</div>
<div class="bookProperty property_volume">
  <div class="property_label">卷:</div>
  <div class="property_value">第21章 赫敏的秘密</div>
</div>
<div class="bookProperty property_year">
  <div class="property_label">年:</div>
  <div class="property_value">2016</div>
</div>
<div class="bookProperty property_publisher">
  <div class="property_label">出版社:</div>
  <div class="property_value">人民文学出版社</div>
</div>
<div class="bookProperty property_language">
  <div class="property_label">语言:</div>
  <div class="property_value"><span class="text-capitalize">中文</span></div>
</div>
<div class="bookProperty property_pages">
  <div class="property_label">页:</div>
  <div class="property_value"><span title="Pages paperback">1298</span></div>
</div>
<div class="bookProperty property_isbn_10">
  <div class="property_label">ISBN 10:</div>
  <div class="property_value">7020034632</div>
</div>
<div class="bookProperty property_isbn_13">
  <div class="property_label">ISBN 13:</div>
  <div class="property_value">9787020034635</div>
</div>
<div class="bookProperty property_series">
  <div class="property_label">系列:</div>
  <div class="property_value">阿兹卡班的囚徒</div>
</div>
<div class="bookProperty property_file">
  <div class="property_label">文件:</div>
  <div class="property_value">EPUB, 28.34 MB</div>
</div>
<div class="bookProperty property_ipfs_cid">
  <div class="property_label">IPFS:</div>
  <div class="property_value">
    <span class="z-copy-icon tooltip-init" data-copy="QMwWibgnN41PZc8pTnUhoY9TWkz3AKZTWcUxWHZ4w5Uf">CID</span>
    ,
    <span class="z-copy-icon tooltip-init" data-copy="bafykbzacecp2ciwl2u5vlutjc2eohitquswtwybrygiyacjp7z3frdbogkkala">CID Blake2b</span>
  </div>
</div>
<div class="bookProperty property_language_year">chinese, 2016</div>
</div></body></html>"#;

    const RATED_HTML: &str = r#"<html><body>
<div class="book-rating-detail">
  <div class="book-rating cursor-pointer">
    <span class="icon star-icon zlibicon-star"></span>
    <span class="icon star-icon zlibicon-star-f"></span>
    <span class="book-rating-interest-score ">
        3.0        </span> /
    <span class="book-rating-quality-score ">
        5.0        </span>
  </div>
</div>
<div class="bookDetailsBox"></div>
</body></html>"#;

    const HIDDEN_HTML: &str = r#"<html><body>
<div class="book-rating-detail">
  <div class="book-rating">
    <span class="book-rating-interest-score none"></span>
    <span class="book-rating-quality-score none"></span>
  </div>
</div>
</body></html>"#;

    #[test]
    fn parses_both_scores_from_rated_book() {
        let meta = parse_book_detail_properties(RATED_HTML);
        assert_eq!(meta.rating_interest.as_deref(), Some("3.0"));
        assert_eq!(meta.rating_quality.as_deref(), Some("5.0"));
    }

    #[test]
    fn unrated_book_hidden_spans_parse_to_none() {
        let meta = parse_book_detail_properties(HIDDEN_HTML);
        assert_eq!(meta.rating_interest, None);
        assert_eq!(meta.rating_quality, None);
        let all_null = meta.volume.is_none()
            && meta.isbn10.is_none()
            && meta.isbn13.is_none()
            && meta.ipfs_cid.is_none()
            && meta.ipfs_cid_blake2b.is_none()
            && meta.rating_interest.is_none()
            && meta.rating_quality.is_none();
        assert!(all_null);
    }

    #[test]
    fn page_without_rating_block_parses_to_none() {
        let meta =
            parse_book_detail_properties("<html><body><div class=\"bookDetailsBox\"></div></body></html>");
        assert_eq!(meta.rating_interest, None);
        assert_eq!(meta.rating_quality, None);
    }

    #[test]
    fn extracts_all_five_values_both_ipfs_cids() {
        let meta = parse_book_detail_properties(DETAIL_HTML);
        assert_eq!(meta.volume.as_deref(), Some("第21章 赫敏的秘密"));
        assert_eq!(meta.isbn10.as_deref(), Some("7020034632"));
        assert_eq!(meta.isbn13.as_deref(), Some("9787020034635"));
        assert_eq!(
            meta.ipfs_cid.as_deref(),
            Some("QMwWibgnN41PZc8pTnUhoY9TWkz3AKZTWcUxWHZ4w5Uf")
        );
        assert_eq!(
            meta.ipfs_cid_blake2b.as_deref(),
            Some("bafykbzacecp2ciwl2u5vlutjc2eohitquswtwybrygiyacjp7z3frdbogkkala")
        );
    }

    #[test]
    fn missing_rows_parse_to_none() {
        let html = "<html><body><div class=\"bookDetailsBox\">\
<div class=\"bookProperty property_year\"><div class=\"property_label\">年:</div><div class=\"property_value\">2016</div></div>\
<div class=\"bookProperty property_publisher\"><div class=\"property_label\">出版社:</div><div class=\"property_value\">人民文学出版社</div></div>\
</div></body></html>";
        let meta = parse_book_detail_properties(html);
        assert_eq!(meta.volume, None);
        assert_eq!(meta.isbn10, None);
        assert_eq!(meta.isbn13, None);
        assert_eq!(meta.ipfs_cid, None);
        assert_eq!(meta.ipfs_cid_blake2b, None);
    }

    #[test]
    fn empty_and_whitespace_values_parse_to_none() {
        let html = "<html><body><div class=\"bookDetailsBox\">\
<div class=\"bookProperty property_volume\"><div class=\"property_label\">卷:</div><div class=\"property_value\">   </div></div>\
<div class=\"bookProperty property_isbn_13\"><div class=\"property_label\">ISBN 13:</div><div class=\"property_value\"></div></div>\
<div class=\"bookProperty property_ipfs_cid\"><div class=\"property_label\">IPFS:</div><div class=\"property_value\"><span data-copy=\"\">CID</span></div></div>\
</div></body></html>";
        let meta = parse_book_detail_properties(html);
        assert_eq!(meta.volume, None);
        assert_eq!(meta.isbn13, None);
        assert_eq!(meta.ipfs_cid, None);
        assert_eq!(meta.ipfs_cid_blake2b, None);
    }

    #[test]
    fn no_book_property_rows_parses_to_all_none() {
        let meta =
            parse_book_detail_properties("<html><body><p>no metadata here</p></body></html>");
        assert_eq!(meta.volume, None);
        assert_eq!(meta.isbn10, None);
        assert_eq!(meta.isbn13, None);
        assert_eq!(meta.ipfs_cid, None);
        assert_eq!(meta.ipfs_cid_blake2b, None);
    }

    #[test]
    fn falls_back_to_label_text_without_class_key() {
        let html = "<html><body><div class=\"bookDetailsBox\">\
<div class=\"bookProperty\"><div class=\"property_label\">Volume:</div><div class=\"property_value\">Part Two</div></div>\
<div class=\"bookProperty\"><div class=\"property_label\">ISBN 13:</div><div class=\"property_value\">9780000000000</div></div>\
</div></body></html>";
        let meta = parse_book_detail_properties(html);
        assert_eq!(meta.volume.as_deref(), Some("Part Two"));
        assert_eq!(meta.isbn13.as_deref(), Some("9780000000000"));
        assert_eq!(meta.isbn10, None);
        assert_eq!(meta.ipfs_cid, None);
    }
}
