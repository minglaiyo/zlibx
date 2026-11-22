//! Open Library trending parser — Rust port of
//! `lib/services/open_library.dart` (`OpenLibrary._parser`).
//!
//! NOTE the exact attribute selectors: Dart's `li[class="…"]` is a
//! full-attribute-value match (not a class-list match), and the img
//! selector carries a trailing space inside the value — both must be
//! reproduced verbatim.

use crate::sel;
use scraper::ElementRef;

use crate::models::TrendingBookData;

/// Parse an Open Library trending page. Mirrors
/// `OpenLibrary._parser(dynamic data)`.
pub(crate) fn parse_trending(html: &str) -> Vec<TrendingBookData> {
    let document = scraper::Html::parse_document(html);
    // Full attribute-value matches, exactly as Dart wrote them
    // (including the trailing space in the img selector).
    let item_sel = sel!(r#"li[class="searchResultItem sri--w-main"]"#);
    let title_sel = sel!(r#"h3[class="booktitle"]"#);
    let img_sel = sel!(r#"img[itemprop="image" ]"#);

    let mut trending = Vec::new();
    for element in document.select(&item_sel) {
        let title_el: Option<ElementRef> = element.select(&title_sel).next();
        let img: Option<ElementRef> = element.select(&img_sel).next();
        let title = title_el.map(|t| t.text().collect::<String>().trim().to_string());
        let src = img.and_then(|i| i.attr("src")).map(|s| s.to_string());
        if title.is_none() || src.is_none() {
            continue;
        }
        let thumb = src.unwrap_or_default();
        // Open Library usually serves protocol-relative src values
        // ("//..."); an absolute https:// src must not be double-prefixed.
        trending.push(TrendingBookData {
            title,
            thumbnail: Some(
                if thumb.starts_with("http") {
                    thumb
                } else {
                    format!("https:{}", thumb)
                },
            ),
        });
    }
    trending
}
