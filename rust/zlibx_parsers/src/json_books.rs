//! eapi JSON → [`Book`] mapping — the Rust port of the Dart hot path
//! `ZLibraryApiBase._booksOf(json)` + `Book.fromJson(json)`.
//!
//! Every search / popular / recent / saved / downloaded feed parses its
//! JSON body through this path, so it is the last un-sunk CPU-heavy
//! parse in the app. The Dart helpers (`_asInt`, `_asString`,
//! `_joinAuthor`, `_filesizeString`, …) are reproduced field-for-field;
//! `test/services/json_books_test.dart` is the differential contract.

use serde_json::Value;

use crate::fulltext::hash_from_href;
use crate::models::Book;

/// Pick the book array from the three shapes the eapi endpoints use:
/// `books` (search), `data` (saved/downloaded), `results` (similar).
/// Mirrors `json['books'] ?? json['data'] ?? json['results']`.
fn books_array<'a>(json: &'a Value) -> Option<&'a Vec<Value>> {
    for key in ["books", "data", "results"] {
        if let Some(arr) = json.get(key).and_then(|v| v.as_array()) {
            return Some(arr);
        }
    }
    None
}

// ── scalar coercion (mirrors the Dart _as* helpers) ────────────────────

/// Dart `_asInt`: int passes through, double truncates toward zero,
/// string is parsed; anything else (or unparsable) → None.
fn as_int(v: &Value) -> Option<i64> {
    match v {
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Some(i)
            } else if let Some(f) = n.as_f64() {
                Some(f as i64) // Dart double.toInt() truncates toward zero
            } else {
                None
            }
        }
        Value::String(s) => s.trim().parse::<i64>().ok(),
        _ => None,
    }
}

/// Dart `_asString`: String passes through, numbers stringify via their
/// own repr, null/absent → None. Booleans and objects have no meaningful
/// Dart toString here, so they map to None (the server never sends them
/// into a string slot).
fn as_string(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(number_to_dart_string(n)),
        _ => None,
    }
}

/// Render a JSON number the way Dart's `num.toString()` does: integral
/// values print without a trailing `.0`, fractional ones keep the digits.
fn number_to_dart_string(n: &serde_json::Number) -> String {
    if let Some(i) = n.as_i64() {
        return i.to_string();
    }
    if let Some(u) = n.as_u64() {
        return u.to_string();
    }
    let f = n.as_f64().unwrap_or(0.0);
    if f.fract() == 0.0 && f.abs() < 1e15 {
        format!("{}", f as i64)
    } else {
        format!("{f}")
    }
}

/// Dart `_nonEmptyString`: `_asString` with empty-string normalization —
/// many endpoints send `""` instead of omitting an optional field.
fn non_empty_string(v: &Value) -> Option<String> {
    as_string(v).filter(|s| !s.is_empty())
}

/// First present value among the candidate keys, mirroring Dart's `??`
/// chain over `json['a'] ?? json['b']`. Returns the raw Value reference.
fn first_present<'a>(json: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter()
        .filter_map(|k| json.get(*k))
        .find(|v| !v.is_null())
}

/// Dart `_joinAuthor`: a list joins non-empty stringified elements with
/// ", "; a scalar falls back to `_asString`. An all-empty list yields ""
/// in Dart, which the model keeps verbatim (not normalized to None).
fn join_author(v: &Value) -> Option<String> {
    match v {
        Value::Array(items) => {
            let parts: Vec<String> = items
                .iter()
                .filter_map(as_string)
                .filter(|s| !s.is_empty())
                .collect();
            Some(parts.join(", "))
        }
        other => as_string(other),
    }
}

/// Dart `_joinCategories`: like authors but an empty result normalizes to
/// None (the caller shows nothing rather than an empty chip).
fn join_categories(v: &Value) -> Option<String> {
    match v {
        Value::Array(items) => {
            let parts: Vec<String> = items
                .iter()
                .filter_map(as_string)
                .filter(|s| !s.is_empty())
                .collect();
            if parts.is_empty() {
                None
            } else {
                Some(parts.join(", "))
            }
        }
        other => as_string(other).filter(|s| !s.is_empty()),
    }
}

/// Dart `_filesizeString`: prefer an explicit string field, else format
/// the byte count with binary units (B / KB 1-dec / MB 2-dec / GB 2-dec).
fn filesize_string(json: &Value) -> Option<String> {
    if let Some(direct) = first_present(json, &["filesizeString", "filesize_string"]) {
        if let Some(s) = as_string(direct) {
            return Some(s);
        }
    }
    let bytes = first_present(json, &["filesize"]).and_then(as_int)?;
    // Negative filesize is meaningless; treat as absent (mirrors Dart's
    // implicit behavior — a negative byte count would produce "-1 B" which
    // is never useful to display).
    if bytes < 0 {
        return None;
    }
    let b = bytes as f64;
    if bytes < 1024 {
        Some(format!("{bytes} B"))
    } else if bytes < 1024 * 1024 {
        Some(format!("{:.1} KB", b / 1024.0))
    } else if bytes < 1024 * 1024 * 1024 {
        Some(format!("{:.2} MB", b / (1024.0 * 1024.0)))
    } else {
        Some(format!("{:.2} GB", b / (1024.0 * 1024.0 * 1024.0)))
    }
}

/// Map one eapi book object. Field-by-field mirror of `Book.fromJson`.
pub(crate) fn book_from_json(json: &Value) -> Book {
    let href_raw = first_present(json, &["href"]).and_then(as_string);
    let hash = first_present(json, &["hash", "hashId"])
        .and_then(non_empty_string)
        .or_else(|| href_raw.as_deref().and_then(hash_from_href));

    let interest_score =
        first_present(json, &["interestScore", "interest_score", "qualityScore"])
            .and_then(as_string);
    let read_online_url =
        first_present(json, &["readOnlineUrl", "read_online_url"]).and_then(as_string);

    Book {
        id: first_present(json, &["id"]).and_then(as_int).unwrap_or(0),
        title: first_present(json, &["title"]).and_then(as_string).unwrap_or_default(),
        hash,
        href: href_raw.clone().filter(|s| !s.is_empty()),
        author: first_present(json, &["author"]).and_then(join_author),
        cover: first_present(json, &["cover"]).and_then(as_string),
        description: first_present(json, &["description"]).and_then(as_string),
        publisher: first_present(json, &["publisher"]).and_then(as_string),
        year: first_present(json, &["year"]).and_then(as_int),
        language: first_present(json, &["language"]).and_then(as_string),
        categories: first_present(json, &["categories"]).and_then(join_categories),
        pages: first_present(json, &["pages"]).and_then(as_int),
        series: first_present(json, &["series"]).and_then(as_string),
        extension: first_present(json, &["extension"]).and_then(as_string),
        filesize: first_present(json, &["filesize"]).and_then(as_int),
        filesize_string: filesize_string(json),
        interest_score,
        read_online_url,
        volume: first_present(json, &["volume"]).and_then(non_empty_string),
        isbn10: first_present(json, &["isbn10", "isbn_10"]).and_then(non_empty_string),
        isbn13: first_present(json, &["isbn13", "isbn_13"]).and_then(non_empty_string),
        ipfs_cid: first_present(json, &["ipfsCid", "ipfs_cid"]).and_then(non_empty_string),
        ipfs_cid_blake2b: first_present(
            json,
            &["ipfsCidBlake2b", "ipfs_cid_blake2b"],
        )
        .and_then(non_empty_string),
        // The eapi book object carries no rating fields (they live in the
        // detail HTML); map them defensively if a future endpoint adds them.
        rating_interest: first_present(json, &["ratingInterest", "rating_interest"])
            .and_then(as_string),
        rating_quality: first_present(json, &["ratingQuality", "rating_quality"])
            .and_then(as_string),
        readlist_book_id: first_present(json, &["readlistBookId", "readlist_book_id"])
            .and_then(as_int),
        note: first_present(json, &["note"]).and_then(non_empty_string),
        // downloadedAt stays an ISO-8601 string on the Rust model; the
        // Dart mapping layer converts it back to DateTime. Epoch numbers
        // are formatted to an ISO string here so both paths agree.
        downloaded_at: first_present(json, &["downloadedAt", "downloaded_at"])
            .and_then(downloaded_at_iso),
    }
}

/// Normalize a timestamp field to an ISO-8601 local string. Strings pass
/// through; epoch seconds/milliseconds convert. Mirrors Dart `_asDateTime`
/// (which rejects <=0 and absurdly large values).
fn downloaded_at_iso(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => {
            if s.is_empty() {
                None
            } else {
                Some(s.clone())
            }
        }
        Value::Number(n) => {
            let raw = n.as_f64()? as i64;
            if raw <= 0 || raw >= 100_000_000_000_000 {
                return None;
            }
            let ms = if raw >= 100_000_000_000 { raw } else { raw * 1000 };
            // Convert epoch millis to a UTC ISO string (no chrono dep):
            // the download-history screen only needs wall-clock fidelity,
            // and the site renders local time already baked into strings.
            Some(epoch_ms_to_iso(ms))
        }
        _ => None,
    }
}

/// Minimal civil-from-days conversion (Howard Hinnant's algorithm) for
/// epoch-ms → `YYYY-MM-DDTHH:MM:SS`. Avoids pulling in `chrono` just to
/// round-trip a timestamp the Dart side re-parses anyway.
fn epoch_ms_to_iso(ms: i64) -> String {
    let secs = ms.div_euclid(1000);
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m as u32, d as u32)
}

/// Parse an eapi JSON body into the book list. Mirrors `_booksOf`.
pub(crate) fn parse_books_json(json_str: &str) -> Vec<Book> {
    let Ok(value) = serde_json::from_str::<Value>(json_str) else {
        return Vec::new();
    };
    match books_array(&value) {
        Some(arr) => arr.iter().filter(|v| v.is_object()).map(book_from_json).collect(),
        None => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_books_key_and_maps_core_fields() {
        let json = r#"{"books":[{"id":123,"title":"书名","href":"/book/eOWaxzXxjb/x.html","author":["张三","李四"],"filesize":1536}]}"#;
        let books = parse_books_json(json);
        assert_eq!(books.len(), 1);
        assert_eq!(books[0].id, 123);
        assert_eq!(books[0].title, "书名");
        // hash derived from href when absent.
        assert_eq!(books[0].hash.as_deref(), Some("eOWaxzXxjb"));
        assert_eq!(books[0].author.as_deref(), Some("张三, 李四"));
        assert_eq!(books[0].filesize, Some(1536));
        assert_eq!(books[0].filesize_string.as_deref(), Some("1.5 KB"));
    }

    #[test]
    fn prefers_explicit_hash_over_href() {
        let json = r#"{"data":[{"id":1,"hash":"ABCdef123","href":"/book/hashed/x.html"}]}"#;
        let books = parse_books_json(json);
        assert_eq!(books[0].hash.as_deref(), Some("ABCdef123"));
    }

    #[test]
    fn empty_hash_string_does_not_shadow_href() {
        // A "" hash must fall through to the href-derived one.
        let json = r#"{"results":[{"id":2,"hash":"","href":"/book/fromHref/x.html"}]}"#;
        let books = parse_books_json(json);
        assert_eq!(books[0].hash.as_deref(), Some("fromHref"));
    }

    #[test]
    fn missing_books_array_yields_empty() {
        assert!(parse_books_json(r#"{"pagination":{}}"#).is_empty());
        assert!(parse_books_json("not json").is_empty());
    }

    #[test]
    fn filesize_units_cover_all_ranges() {
        let cases = [
            (512usize, "512 B"),
            (1024, "1.0 KB"),
            (1024 * 1024, "1.00 MB"),
            (1024 * 1024 * 1024, "1.00 GB"),
        ];
        for (bytes, want) in cases {
            let json = format!(r#"{{"books":[{{"id":1,"filesize":{bytes}}}]}}"#);
            let books = parse_books_json(&json);
            assert_eq!(books[0].filesize_string.as_deref(), Some(want), "bytes={bytes}");
        }
    }

    #[test]
    fn numeric_year_and_double_coercion() {
        let json = r#"{"books":[{"id":1,"year":2019,"filesize":1.9}]}"#;
        let books = parse_books_json(json);
        assert_eq!(books[0].year, Some(2019));
        // double truncates toward zero like Dart toInt().
        assert_eq!(books[0].filesize, Some(1));
    }

    #[test]
    fn categories_joined_or_null() {
        let json = r#"{"books":[{"id":1,"categories":["Fiction","Horror"]},{"id":2,"categories":[]}]}"#;
        let books = parse_books_json(json);
        assert_eq!(books[0].categories.as_deref(), Some("Fiction, Horror"));
        assert_eq!(books[1].categories, None);
    }
}
