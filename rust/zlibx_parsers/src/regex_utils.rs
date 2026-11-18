//! Unified regex extraction utilities — replaces scattered Dart RegExp calls.
//!
//! All patterns are pre-compiled via `OnceLock` (CLAUDE.md convention: cached
//! regexes cost 13× less than per-call re-compilation on the hot path).
//! Each function is a pure synchronous parser, safe to call from FRB's
//! thread pool.

use std::sync::OnceLock;

use regex::Regex;

// ── pagesTotal extraction ────────────────────────────────────────────────
// Used by: fulltext.dart, category.dart, booklist.dart, article_search.dart
// Pattern: "pagesTotal": <number> or "pagesTotal" : <number>

fn pages_total_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#""?pagesTotal"?\s*[:=]\s*(\d+)"#).expect("valid pagesTotal regex")
    })
}

/// Extract the total page count from a search/category/booklist results page.
///
/// Mirrors the Dart pattern `RegExp(r'pagesTotal\s*:\s*(\d+)').firstMatch(html)`.
/// Returns `None` when the marker is absent or the value overflows u64.
pub(crate) fn extract_pages_total(html: &str) -> Option<u64> {
    pages_total_re()
        .captures(html)
        .and_then(|c| c[1].parse().ok())
}

// ── numeric ID validation ────────────────────────────────────────────────
// Used by: booklist.dart (id check), zlibrary_booklists.dart
// Pattern: ^\d+$

fn numeric_id_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^\d+$").expect("valid numeric id regex"))
}

/// Validate that a string is purely ASCII digits (booklist / comment IDs).
///
/// Mirrors the Dart pattern `RegExp(r'^\d+$').hasMatch(id)`.
pub(crate) fn is_numeric_id(s: &str) -> bool {
    numeric_id_re().is_match(s)
}

// ── hex token validation ─────────────────────────────────────────────────
// Used by: fulltext.dart (extractFulltextToken)
// Pattern: ^[0-9a-fA-F]{8}$

fn hex_token_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^[0-9a-fA-F]{8}$").expect("valid hex token regex")
    })
}

/// Validate an 8-character hexadecimal session token.
///
/// Mirrors the Dart pattern `RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(value)`.
pub(crate) fn is_hex_token(s: &str) -> bool {
    hex_token_re().is_match(s)
}

// ── date format detection ────────────────────────────────────────────────
// Used by: download_stats.dart
// Patterns: ^\d{1,2}\.\d{1,2}\.\d{4}$ and ^\d{1,2}:\d{2}$

fn date_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^(\d{1,2})\.(\d{1,2})\.(\d{4})$").expect("valid date regex")
    })
}

fn time_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^(\d{1,2}):(\d{2})$").expect("valid time regex")
    })
}

/// Check if text matches DD.MM.YYYY date format.
pub(crate) fn is_date_text(s: &str) -> bool {
    date_re().is_match(s)
}

/// Check if text matches HH:mm time format.
pub(crate) fn is_time_text(s: &str) -> bool {
    time_re().is_match(s)
}

/// Parse a DD.MM.YYYY date string into components.
/// Returns (day, month, year) or None if no match.
pub(crate) fn parse_date_parts(s: &str) -> Option<(u32, u32, u32)> {
    let caps = date_re().captures(s)?;
    Some((
        caps[1].parse().ok()?,
        caps[2].parse().ok()?,
        caps[3].parse().ok()?,
    ))
}

/// Parse a HH:mm time string into components.
/// Returns (hour, minute) or None if no match.
pub(crate) fn parse_time_parts(s: &str) -> Option<(u32, u32)> {
    let caps = time_re().captures(s)?;
    Some((caps[1].parse().ok()?, caps[2].parse().ok()?))
}

// ── URL normalization ────────────────────────────────────────────────────
// Used by: zlibrary_api.dart Line 125-129
// Patterns: strip scheme, cut at first [/?#]

fn scheme_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^https?://").expect("valid scheme regex"))
}

fn url_path_cut_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[/?#]").expect("valid url path cut regex"))
}

/// Strip http:// or https:// prefix from a domain string.
///
/// Mirrors `d.replaceFirst(RegExp(r'^https?://'), '')`.
pub(crate) fn strip_url_scheme(s: &str) -> String {
    scheme_re().replace(s, "").to_string()
}

/// Cut a domain string at the first `/`, `?`, or `#`.
///
/// Mirrors `d.indexOf(RegExp(r'[/?#]'))` + substring logic.
pub(crate) fn cut_at_first_path_sep(s: &str) -> &str {
    url_path_cut_re()
        .find(s)
        .map_or(s, |m| &s[..m.start()])
}

// ── HTML cleanup for booklist cache ──────────────────────────────────────
// Used by: booklist_html_cache.dart Line 112

fn script_tag_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?is)<script[^>]*>.*?</script>").expect("valid script tag regex")
    })
}

fn html_comment_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?s)<!--[\s\S]*?-->").expect("valid comment regex")
    })
}

fn whitespace_collapse_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\s+").expect("valid whitespace regex"))
}

/// Remove `<script>` tags and HTML comments from a cached page body.
/// Collapses runs of whitespace to a single space.
///
/// # ⚠️ NOT safe for rendering
///
/// This function uses regex-based stripping, which is **not** a proper HTML
/// sanitizer. Nested or malformed tags (e.g. `<scr<script>ipt>`) can bypass
/// the pattern. The output is intended **only** for server-side text extraction
/// (the booklist HTML cache is parsed by Rust/Dart parsers, never rendered in
/// a WebView). If you need to render cleaned HTML in a browser or WebView,
/// use a dedicated sanitizer such as the `ammonia` crate instead.
pub(crate) fn clean_html_for_cache(html: &str) -> String {
    let without_scripts = script_tag_re().replace_all(html, "");
    let without_comments = html_comment_re().replace_all(&without_scripts, "");
    whitespace_collapse_re()
        .replace_all(&without_comments, " ")
        .trim()
        .to_string()
}

// ── Range header parsing ─────────────────────────────────────────────────
// Used by: download_range.dart Lines 43-44, 78-79
// Patterns: bytes <start>- , bytes */<total>

fn range_start_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)^\s*bytes\s+(\d+)-").expect("valid range start regex")
    })
}

fn range_total_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)bytes\s+\*/\s*(\d+)").expect("valid range total regex")
    })
}

/// Parse the byte-offset from a Content-Range header like `bytes 1024-2047/5000`.
pub(crate) fn parse_range_start(content_range: &str) -> Option<u64> {
    range_start_re()
        .captures(content_range)
        .and_then(|c| c[1].parse().ok())
}

/// Parse the total size from a Content-Range header like `bytes */5000`.
pub(crate) fn parse_range_total(content_range: &str) -> Option<u64> {
    range_total_re()
        .captures(content_range)
        .and_then(|c| c[1].parse().ok())
}

// ── Category slug extraction ─────────────────────────────────────────────
// Used by: category.dart Line 149
// Pattern: /category/\d+/([^/]+)/s/

fn category_slug_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"/category/\d+/([^/]+)/s/").expect("valid category slug regex")
    })
}

/// Extract the category slug from a form action URL like `/category/123/fiction/s/`.
pub(crate) fn extract_category_slug(action: &str) -> Option<String> {
    category_slug_re()
        .captures(action)
        .map(|c| c[1].to_string())
}

// ── Article query echo extraction ────────────────────────────────────────
// Used by: article_search.dart Line 256, fulltext.dart Line 282
// These need the surrounding HTML context, so we return the raw capture.
//
// Only two input names are ever queried in practice ("q" and "token"), so
// we cache both patterns via OnceLock instead of re-compiling per call
// (CLAUDE.md: "Regexes are cached in OnceLock — re-compiling per call
// cost 13× on the hot path").

fn input_value_re_for_q() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"(?is)<input[^>]*?(?:name=["']q["'][^>]*?value=["']([^"']*)["']|value=["']([^"']*)["'][^>]*?name=["']q["'])"#,
        )
        .expect("valid input[q] regex")
    })
}

fn input_value_re_for_token() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"(?is)<input[^>]*?(?:name=["']token["'][^>]*?value=["']([^"']*)["']|value=["']([^"']*)["'][^>]*?name=["']token["'])"#,
        )
        .expect("valid input[token] regex")
    })
}

/// Extract the echoed query string from a results page's hidden input field.
/// Returns None when the input is missing or its value is empty.
///
/// Only `"q"` and `"token"` are supported (the only names used in the app).
/// Other names return None immediately without compiling a regex.
pub(crate) fn extract_input_value(html: &str, input_name: &str) -> Option<String> {
    let re = match input_name {
        "q" => input_value_re_for_q(),
        "token" => input_value_re_for_token(),
        _ => return None, // Unknown input name; not worth compiling dynamically.
    };
    let caps = re.captures(html)?;
    // Group 1 = value when name comes first; group 2 = value when value comes first.
    let val = caps
        .get(1)
        .or_else(|| caps.get(2))
        .map_or("", |m| m.as_str())
        .to_string();
    if val.is_empty() {
        None
    } else {
        Some(val)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_pages_total() {
        assert_eq!(extract_pages_total(r#"{"pagesTotal": 42}"#), Some(42));
        assert_eq!(extract_pages_total(r#"pagesTotal : 100"#), Some(100));
        assert_eq!(extract_pages_total(r#"no marker here"#), None);
    }

    #[test]
    fn test_is_numeric_id() {
        assert!(is_numeric_id("12345"));
        assert!(!is_numeric_id("abc"));
        assert!(!is_numeric_id(""));
        assert!(!is_numeric_id("12.3"));
    }

    #[test]
    fn test_is_hex_token() {
        assert!(is_hex_token("a1b2c3d4"));
        assert!(is_hex_token("AABBCCDD"));
        assert!(!is_hex_token("short"));
        assert!(!is_hex_token("g1h2i3j4"));
    }

    #[test]
    fn test_date_time_validation() {
        assert!(is_date_text("15.03.2024"));
        assert!(!is_date_text("2024-03-15"));
        assert!(is_time_text("9:30"));
        assert!(is_time_text("14:05"));
        // \d{1,2} matches "25" — semantic validation is the caller's job.
        assert!(is_time_text("25:00"));
    }

    #[test]
    fn test_parse_date_parts() {
        assert_eq!(parse_date_parts("15.03.2024"), Some((15, 3, 2024)));
        assert_eq!(parse_date_parts("invalid"), None);
    }

    #[test]
    fn test_parse_time_parts() {
        assert_eq!(parse_time_parts("14:05"), Some((14, 5)));
        assert_eq!(parse_time_parts("bad"), None);
    }

    #[test]
    fn test_strip_url_scheme() {
        assert_eq!(strip_url_scheme("https://zlib.us"), "zlib.us");
        assert_eq!(strip_url_scheme("http://example.com"), "example.com");
        assert_eq!(strip_url_scheme("plain.domain"), "plain.domain");
    }

    #[test]
    fn test_cut_at_first_path_sep() {
        assert_eq!(cut_at_first_path_sep("domain/path?q=1"), "domain");
        assert_eq!(cut_at_first_path_sep("domain#frag"), "domain");
        assert_eq!(cut_at_first_path_sep("pure-domain"), "pure-domain");
    }

    #[test]
    fn test_clean_html_for_cache() {
        let dirty = "<div>Hello</div><script>alert('x')</script><!-- note --><p>World</p>";
        let cleaned = clean_html_for_cache(dirty);
        assert!(!cleaned.contains("alert"));
        assert!(!cleaned.contains("note"));
        assert!(cleaned.contains("Hello"));
    }

    #[test]
    fn test_parse_range_headers() {
        assert_eq!(parse_range_start("bytes 1024-2047/5000"), Some(1024));
        assert_eq!(parse_range_start("not a range"), None);
        assert_eq!(parse_range_total("bytes */5000"), Some(5000));
    }

    #[test]
    fn test_extract_category_slug() {
        assert_eq!(
            extract_category_slug("/category/123/fiction/s/"),
            Some("fiction".to_string())
        );
        assert_eq!(extract_category_slug("/other/path/"), None);
    }

    #[test]
    fn test_extract_input_value() {
        let html = r#"<form><input type="hidden" name="q" value="hello world"></form>"#;
        assert_eq!(extract_input_value(html, "q"), Some("hello world".to_string()));
        let empty = r#"<input name="q" value="">"#;
        assert_eq!(extract_input_value(empty, "q"), None);
    }
}
