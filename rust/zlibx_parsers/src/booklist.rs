//! Booklist page parsers — Rust port of
//! `vendor/olib_api_plugin/lib/src/booklist.dart` (the HTML entries;
//! `parseRecommendedBooklists` is a JSON parser and stays in Dart).

use crate::sel;
use scraper::{ElementRef, Node};

use crate::fulltext::{attr, hash_from_href, resolve_card_url};
use crate::models::{Book, Booklist, BooklistsPage};

// ──────────────────────────────────────────────────────────────────
// Entry points
// ──────────────────────────────────────────────────────────────────

/// Parse a `/booklists` (or `/booklists/my`) list page into a
/// [`BooklistsPage`]. An empty `<z-booklist>` set parses to an empty
/// list; `total_pages` is 0 when the page carried no count.
///
/// Mirrors `parseBooklistsPage(String html, {required String baseUrl})`.
/// NOTE the Dart regex here is `pagesTotal:\s*(\d+)` — no `\s*` before
/// the colon (unlike the fulltext/article variant); kept verbatim.
pub(crate) fn parse_booklists_page(html: &str, base_url: &str) -> BooklistsPage {
    let doc = scraper::Html::parse_document(html);
    let sel = sel!("z-booklist");
    let lists: Vec<Booklist> = doc
        .select(&sel)
        .filter_map(|el| booklist_from_element(&el, base_url))
        .collect();
    let mut total_pages = 0i64;
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let re = RE.get_or_init(|| regex::Regex::new(r"pagesTotal:\s*(\d+)").unwrap());
    if let Some(m) = re.captures(html) {
        if let Some(g) = m.get(1) {
            total_pages = g.as_str().parse::<i64>().unwrap_or(0);
        }
    }
    BooklistsPage { lists, total_pages }
}

/// Booklists on one user's profile page, from the `<z-booklist>`
/// elements inside `<div z-tab="booklists">`.
///
/// Mirrors `parseUserProfileBooklists(String html, {required String baseUrl})`.
pub(crate) fn parse_user_profile_booklists(
    html: &str,
    base_url: &str,
) -> Vec<Booklist> {
    let doc = scraper::Html::parse_document(html);
    let tab_sel = sel!(r#"div[z-tab="booklists"]"#);
    let tab = match doc.select(&tab_sel).next() {
        Some(t) => t,
        None => return Vec::new(),
    };
    let sel = sel!("z-booklist");
    tab.select(&sel)
        .filter_map(|el| booklist_from_element(&el, base_url))
        .collect()
}

/// Books on the FIRST page of a booklist detail page, from the
/// server-rendered `<z-bookcard>` elements (`.readlist-view`).
///
/// Mirrors `parseBooklistDetailBooks(String html, {String? baseUrl})`.
pub(crate) fn parse_booklist_detail_books(
    html: &str,
    base_url: Option<&str>,
) -> Vec<Book> {
    let doc = scraper::Html::parse_document(html);
    let view_sel = sel!(".readlist-view");
    let card_sel = sel!("z-bookcard");
    let cards: Vec<ElementRef> = match doc.select(&view_sel).next() {
        Some(view) => view.select(&card_sel).collect(),
        None => doc.select(&card_sel).collect(),
    };
    let mut books = Vec::new();
    for card in cards {
        let id: i64 = match card.attr("id").unwrap_or("").trim().parse() {
            Ok(v) => v,
            Err(_) => continue,
        };
        // deleted="1" cards are skipped (removed books stay out of the
        // detail list, unlike the fulltext/category pages which keep
        // them greyed).
        if card.attr("deleted").unwrap_or("").trim() == "1" {
            continue;
        }
        let href = card.attr("href").unwrap_or("").trim().to_string();
        let img = card.select(&sel!("img")).next();
        let cover_raw = img
            .and_then(|i| {
                i.attr("data-src")
                    .map(|s| s.trim().to_string())
                    .or_else(|| i.attr("src").map(|s| s.trim().to_string()))
            })
            .unwrap_or_default();
        let title = card
            .select(&sel!(r#"div[slot="title"]"#))
            .next()
            .map(|e| e.text().collect::<String>())
            .unwrap_or_default()
            .trim()
            .to_string();
        let author = card
            .select(&sel!(r#"div[slot="author"]"#))
            .next()
            .map(|e| e.text().collect::<String>())
            .unwrap_or_default()
            .trim()
            .to_string();
        let note = card
            .select(&sel!(r#"div[slot="note"]"#))
            .next()
            .map(|e| e.text().collect::<String>())
            .unwrap_or_default()
            .trim()
            .to_string();
        let cover = if cover_raw.is_empty() {
            None
        } else if let Some(base) = base_url {
            Some(resolve_card_url(&cover_raw, base))
        } else {
            Some(cover_raw)
        };
        books.push(Book {
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
            readlist_book_id: card
                .attr("booklistsindex")
                .unwrap_or("")
                .trim()
                .parse::<i64>()
                .ok(),
            note: if note.is_empty() { None } else { Some(note) },
            downloaded_at: None,
        });
    }
    books
}

// ──────────────────────────────────────────────────────────────────
// Booklist.fromElement
// ──────────────────────────────────────────────────────────────────

/// Build one [`Booklist`] from a `<z-booklist>` element. Returns None
/// when the element has no usable name or id.
///
/// Mirrors `Booklist.fromElement`.
fn booklist_from_element(el: &ElementRef, base_url: &str) -> Option<Booklist> {
    let name = el.attr("topic").map(|s| s.trim().to_string())?;
    if name.is_empty() {
        return None;
    }
    let href = el.attr("href").unwrap_or("").trim().to_string();
    // Numeric id attribute wins; else the booklists/booklist href segment.
    let id_attr = el.attr("id").map(|s| s.trim().to_string());
    static DIGITS: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let digits = DIGITS.get_or_init(|| regex::Regex::new(r"^\d+$").unwrap());
    let id = match id_attr {
        Some(ref v) if digits.is_match(v) => v.clone(),
        _ => id_from_href(&href)?,
    };

    // Cover: the first z-cover's img data-src; fall back to the
    // whole-element scan (first non-empty img data-src) only when
    // there is no carousel at all.
    let cover_sel = sel!("z-cover");
    let img_sel = sel!("img");
    let mut cover_url = String::new();
    let first_cover = el.select(&cover_sel).next();
    let first_src = first_cover
        .and_then(|c| c.select(&img_sel).next())
        .and_then(|img| img.attr("data-src").map(|s| s.trim().to_string()))
        .unwrap_or_default();
    if !first_src.is_empty() {
        cover_url = resolve_card_url(&first_src, base_url);
    } else {
        for img in el.select(&img_sel) {
            let src = img.attr("data-src").unwrap_or("").trim().to_string();
            if !src.is_empty() {
                cover_url = resolve_card_url(&src, base_url);
                break;
            }
        }
    }

    // Preview books: each z-cover carries id/title/author attributes,
    // the cover in a child img, and the hash in the nearest ancestor
    // <a href="/book/{hash}/...">.
    let mut preview_books = Vec::new();
    for cover in el.select(&cover_sel) {
        let book_id: i64 = match cover.attr("id").unwrap_or("").trim().parse() {
            Ok(v) => v,
            Err(_) => continue,
        };
        let img = cover.select(&img_sel).next();
        let cover_raw = img
            .and_then(|i| {
                i.attr("data-src")
                    .map(|s| s.trim().to_string())
                    .or_else(|| i.attr("src").map(|s| s.trim().to_string()))
            })
            .unwrap_or_default();
        let link_href = nearest_ancestor_a_href(&cover).unwrap_or_default();
        let cover_val = if cover_raw.is_empty() {
            None
        } else {
            Some(resolve_card_url(&cover_raw, base_url))
        };
        preview_books.push(Book {
            id: book_id,
            title: cover.attr("title").unwrap_or("").trim().to_string(),
            hash: hash_from_href(&link_href),
            href: None,
            author: attr(&cover, "author"),
            cover: cover_val,
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
            downloaded_at: None,
        });
    }

    // Author: the `author` attribute wins; authorprofile is only a
    // fallback for a page shape that carries no author attribute.
    let author_name = {
        let a = el.attr("author").unwrap_or("").trim().to_string();
        if a.is_empty() {
            el.attr("authorprofile").unwrap_or("").trim().to_string()
        } else {
            a
        }
    };

    Some(Booklist {
        id,
        name,
        description: el.attr("description").unwrap_or("").trim().to_string(),
        author: author_name,
        author_profile: el.attr("authorprofile").unwrap_or("").trim().to_string(),
        author_avatar: resolve_card_url(
            el.attr("authoravatar").unwrap_or("").trim(),
            base_url,
        ),
        count: el.attr("quantity").unwrap_or("").trim().parse::<i64>().ok(),
        views: el.attr("views").unwrap_or("").trim().to_string(),
        comments: el.attr("comments").unwrap_or("").trim().to_string(),
        color: el.attr("color").unwrap_or("").trim().parse::<i64>().ok(),
        // Boolean attributes: presence is what matters (containsKey).
        is_private: el.attr("private").is_some(),
        is_favorite: el.attr("favorite").is_some(),
        cover_url,
        url: resolve_card_url(&href, base_url),
        preview_books,
    })
}

/// The href of the nearest ancestor `<a>` element (Dart walks
/// `cover.parent` up until an `<a>` is found).
fn nearest_ancestor_a_href(cover: &ElementRef) -> Option<String> {
    let mut node: ego_tree::NodeRef<'_, Node> = **cover;
    loop {
        node = node.parent()?;
        if let Node::Element(el) = node.value() {
            if el.name.local.as_ref() == "a" {
                return ElementRef::wrap(node).and_then(|e| {
                    e.attr("href").map(|s| s.to_string())
                });
            }
        }
    }
}

/// The list id: the path segment after `/booklists/` or the singular
/// `/booklist/`. Mirrors `_idFromHref`.
fn id_from_href(href: &str) -> Option<String> {
    if href.is_empty() {
        return None;
    }
    let path = href.split(['?', '#']).next().unwrap_or(href);
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    let at = segments.iter().position(|s| *s == "booklists");
    let at = match at {
        Some(a) => Some(a),
        None => segments.iter().position(|s| *s == "booklist"),
    };
    let at = at?;
    let id = segments.get(at + 1)?;
    if id.is_empty() {
        None
    } else {
        Some((*id).to_string())
    }
}

// ──────────────────────────────────────────────────────────────────
// Tests — differential baselines from test/parsers/booklist_page_test.dart,
// user_profile_booklists_test.dart, booklist_detail_test.dart
// ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    const BASE: &str = "https://zh.z-library.sk";

    const MY_BOOKLISTS_HTML: &str = r#"<html><body>
<z-booklist id="4088695" href="/booklist/4088695/62a0c2/001.html" topic="001" author="徕" authorprofile="/profile/35899435/5a9053" quantity="4" views="12" comments="3" color="4" private favorite>
<a href="/book/abc123def456/slug-one.html"><z-cover id="5740686" author="霍格尔·丹贝克" title="你学的数学可能是假的"><img data-src="https://cdn.example.com/covers200/collections/userbooks/1.jpg"></z-cover></a>
<a href="/book/9876543210abcdef/slug-two.html"><z-cover id="5288001" author="作者二" title="第二本书"><img data-src="https://cdn.example.com/covers200/collections/userbooks/2.jpg"></z-cover></a>
</z-booklist>
<z-booklist href="/booklists/777/xyz/公开书单.html" topic="公开书单" quantity="2"></z-booklist>
<z-booklist href="/booklists/999/x/y.html"></z-booklist>
<script>var pagerOptions = {pagesTotal: 3, foo: 1};</script>
</body></html>"#;

    #[test]
    fn parses_lists_carousel_previews_and_page_count() {
        let page = parse_booklists_page(MY_BOOKLISTS_HTML, BASE);
        assert_eq!(page.total_pages, 3);
        assert_eq!(page.lists.len(), 2);

        let first = &page.lists[0];
        assert_eq!(first.id, "4088695");
        assert_eq!(first.name, "001");
        assert_eq!(first.author, "徕");
        assert_eq!(first.author_profile, "/profile/35899435/5a9053");
        assert_eq!(first.author_avatar, "");
        assert_eq!(first.count, Some(4));
        assert_eq!(first.views, "12");
        assert_eq!(first.comments, "3");
        assert_eq!(first.color, Some(4));
        assert!(first.is_private);
        assert!(first.is_favorite);
        assert_eq!(first.url, format!("{BASE}/booklist/4088695/62a0c2/001.html"));
        assert_eq!(
            first.cover_url,
            "https://cdn.example.com/covers200/collections/userbooks/1.jpg"
        );
        assert_eq!(first.preview_books.len(), 2);
        let pb0 = &first.preview_books[0];
        assert_eq!(pb0.id, 5740686);
        assert_eq!(pb0.title, "你学的数学可能是假的");
        assert_eq!(pb0.author.as_deref(), Some("霍格尔·丹贝克"));
        assert_eq!(pb0.hash.as_deref(), Some("abc123def456"));
        assert_eq!(
            pb0.cover.as_deref(),
            Some("https://cdn.example.com/covers200/collections/userbooks/1.jpg")
        );
        assert_eq!(first.preview_books[1].id, 5288001);
        assert_eq!(
            first.preview_books[1].hash.as_deref(),
            Some("9876543210abcdef")
        );
    }

    #[test]
    fn plural_href_id_fallback() {
        let page = parse_booklists_page(MY_BOOKLISTS_HTML, BASE);
        let second = &page.lists[1];
        assert_eq!(second.id, "777");
        assert_eq!(second.name, "公开书单");
        assert_eq!(second.count, Some(2));
        assert!(second.preview_books.is_empty());
    }

    #[test]
    fn singular_booklist_href_regression_build_46() {
        let html = r#"<z-booklist href="/booklist/4088695/62a0c2/001.html" topic="001" quantity="4"></z-booklist>"#;
        let page = parse_booklists_page(html, BASE);
        assert_eq!(page.lists.len(), 1);
        assert_eq!(page.lists[0].id, "4088695");
    }

    #[test]
    fn empty_page_empty_list_unknown_count() {
        let page = parse_booklists_page("<html><body><p>nothing here</p></body></html>", BASE);
        assert!(page.lists.is_empty());
        assert_eq!(page.total_pages, 0);
    }

    #[test]
    fn list_without_page_count_reports_zero() {
        let html = r#"<z-booklist id="1" href="/booklist/1/a/x.html" topic="X"></z-booklist>"#;
        let page = parse_booklists_page(html, BASE);
        assert_eq!(page.lists.len(), 1);
        assert_eq!(page.total_pages, 0);
    }

    const PROFILE_HTML: &str = r#"<html><body>
<div z-tab="plans"></div>
<div z-tab="comments">
<z-comments total="1" type="user" id="21490583" username="someone" avatar="" lang="zh" sorting="asc"></z-comments>
</div>
<div z-tab="booklists">
<div class="booklists-list">
<z-booklist id="2690671" href="/booklist/2690671/2ac488/math-list.html" topic="数学书单" author="someone" authorProfile="/booklists/user/21490583" authorAvatar="" quantity="15" views="29" comments="0" description="" color="0">
<a href="/book/abcdef123456/slug-one.html"><z-cover id="1045682" author="Author One" title="第一本书"><img data-src="https://cdn.example.com/1.jpg"></z-cover></a>
<a href="/book/9876543210abcdef/slug-two.html"><z-cover id="5471430" author="Author Two" title="第二本书"><img data-src="https://cdn.example.com/2.jpg"></z-cover></a>
</z-booklist>
<z-booklist id="2690672" href="/booklist/2690672/abc/other-list.html" topic="另一书单" author="someone" authorProfile="/booklists/user/21490583" authorAvatar="" quantity="3" views="8" comments="0" description="desc" color="0"></z-booklist>
</div>
</div>
</body></html>"#;

    #[test]
    fn profile_booklists_tab_with_previews() {
        let lists = parse_user_profile_booklists(PROFILE_HTML, BASE);
        assert_eq!(lists.len(), 2);
        let first = &lists[0];
        assert_eq!(first.id, "2690671");
        assert_eq!(first.name, "数学书单");
        assert_eq!(first.author, "someone");
        assert_eq!(first.author_profile, "/booklists/user/21490583");
        assert_eq!(first.author_avatar, "");
        assert_eq!(first.count, Some(15));
        assert_eq!(first.views, "29");
        assert_eq!(first.comments, "0");
        assert_eq!(first.color, Some(0));
        assert!(!first.is_private);
        assert!(!first.is_favorite);
        assert_eq!(first.url, format!("{BASE}/booklist/2690671/2ac488/math-list.html"));
        assert_eq!(first.cover_url, "https://cdn.example.com/1.jpg");
        assert_eq!(first.preview_books.len(), 2);
        assert_eq!(first.preview_books[0].id, 1045682);
        assert_eq!(first.preview_books[0].title, "第一本书");
        assert_eq!(first.preview_books[0].author.as_deref(), Some("Author One"));
        assert_eq!(first.preview_books[0].hash.as_deref(), Some("abcdef123456"));
        assert_eq!(first.preview_books[1].id, 5471430);
        let second = &lists[1];
        assert_eq!(second.id, "2690672");
        assert_eq!(second.name, "另一书单");
        assert_eq!(second.count, Some(3));
        assert_eq!(second.description, "desc");
        assert!(second.preview_books.is_empty());
    }

    #[test]
    fn empty_or_missing_booklists_tab_parses_empty() {
        let empty = "<html><body><div z-tab=\"comments\"><z-comments total=\"0\"></z-comments></div><div z-tab=\"booklists\"></div></body></html>";
        assert!(parse_user_profile_booklists(empty, BASE).is_empty());
        let missing = "<html><body><div z-tab=\"comments\"><z-comments total=\"1\"></z-comments></div></body></html>";
        assert!(parse_user_profile_booklists(missing, BASE).is_empty());
    }

    const DETAIL_HTML: &str = r#"<div class="readlist-view">
<z-bookcard library id="5288001" isbn="978-7-01-000000-0" termshash="abc" href="/book/a1b2c3d4e5f6a7b8/slug-one.html" download="/dl/5288001/xyz" deleted="0" publisher="出版社A" language="Chinese" year="2020" extension="epub" filesize="13.38 MB" rating="5.0" quality="1" user_token="FAKE.JWT.TOKEN-DO-NOT-USE" read="https://reader.example.com/read/abc" contentTypeParam="" booklisted="true" booklistsindex="555001">
<img data-src="https://cdn.example.com/covers100/collections/userbooks/1.jpg">
<div slot="title">第一本书</div>
<div slot="author">作者甲; 作者乙</div>
<div slot="note">笔记</div>
<div slot="extend"><z-tags bookid="5288001"></z-tags></div>
</z-bookcard>
<z-bookcard library id="5722200" href="/book/0123456789abcdef/slug-two.html" deleted="0" publisher="出版社B" language="English" year="2021" extension="pdf" filesize="2.06 MB" rating="4.5" read="https://reader.example.com/read/def">
<img src="https://cdn.example.com/covers100/2.jpg">
<div slot="title">Second Book</div>
<div slot="author">Author B</div>
</z-bookcard>
<z-bookcard library id="999" href="/book/deadbeef/slug-deleted.html" deleted="1"><div slot="title">已删除</div></z-bookcard>
<z-bookcard library href="/book/nonumeric/slug.html" deleted="0"><div slot="title">无 id</div></z-bookcard>
</div>"#;

    #[test]
    fn detail_books_skip_deleted_and_idless() {
        let books = parse_booklist_detail_books(DETAIL_HTML, None);
        assert_eq!(books.len(), 2);

        let first = &books[0];
        assert_eq!(first.id, 5288001);
        assert_eq!(first.title, "第一本书");
        assert_eq!(first.hash.as_deref(), Some("a1b2c3d4e5f6a7b8"));
        assert_eq!(first.author.as_deref(), Some("作者甲; 作者乙"));
        assert_eq!(
            first.cover.as_deref(),
            Some("https://cdn.example.com/covers100/collections/userbooks/1.jpg")
        );
        assert_eq!(first.publisher.as_deref(), Some("出版社A"));
        assert_eq!(first.year, Some(2020));
        assert_eq!(first.language.as_deref(), Some("Chinese"));
        assert_eq!(first.extension.as_deref(), Some("epub"));
        assert_eq!(first.filesize_string.as_deref(), Some("13.38 MB"));
        assert_eq!(first.interest_score.as_deref(), Some("5.0"));
        assert_eq!(
            first.read_online_url.as_deref(),
            Some("https://reader.example.com/read/abc")
        );
        assert_eq!(first.readlist_book_id, Some(555001));
        assert_eq!(first.note.as_deref(), Some("笔记"));

        let second = &books[1];
        assert_eq!(second.id, 5722200);
        assert_eq!(second.hash.as_deref(), Some("0123456789abcdef"));
        // Cover falls back to plain src when data-src is absent.
        assert_eq!(
            second.cover.as_deref(),
            Some("https://cdn.example.com/covers100/2.jpg")
        );
        assert_eq!(second.extension.as_deref(), Some("pdf"));
        assert_eq!(second.readlist_book_id, None);
        assert_eq!(second.note, None);
    }

    #[test]
    fn detail_books_never_read_user_token() {
        let books = parse_booklist_detail_books(DETAIL_HTML, None);
        assert_eq!(books.len(), 2);
        for b in &books {
            let t = format!(
                "{:?}{:?}{:?}{:?}{:?}{:?}{:?}{:?}{:?}",
                b.title, b.author, b.cover, b.hash, b.publisher, b.language,
                b.extension, b.filesize_string, b.note
            );
            assert!(!t.contains("FAKE.JWT.TOKEN-DO-NOT-USE"));
        }
    }

    #[test]
    fn detail_books_resolve_relative_cover() {
        let html = r#"<z-bookcard id="1" href="/book/abcdef/slug.html" deleted="0">
<img data-src="/covers100/x.jpg">
<div slot="title">T</div>
</z-bookcard>"#;
        let books = parse_booklist_detail_books(html, Some(BASE));
        assert_eq!(books.len(), 1);
        assert_eq!(
            books[0].cover.as_deref(),
            Some("https://zh.z-library.sk/covers100/x.jpg")
        );
    }

    #[test]
    fn detail_page_without_cards_parses_empty() {
        assert!(parse_booklist_detail_books("<html><body>not a detail page</body></html>", None).is_empty());
        assert!(parse_booklist_detail_books("", None).is_empty());
    }
}
