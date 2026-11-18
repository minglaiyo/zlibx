//! Data models for zlibx_parsers.
//!
//! These mirror the Dart models in `vendor/olib_api_plugin/lib/src/book.dart`
//! and `fulltext.dart`. FRB v2 maps each field to the corresponding Dart type:
//! `String` → `String`, `Option<String>` → `String?`, `i64` → `int` (with
//! `--type-64bit-int`), `Vec<T>` → `List<T>`, `bool` → `bool`.

/// One book, mirroring `Book` in `book.dart`.
///
/// Only the fields populated by a given parser are set; the rest remain
/// `None`. `downloadedAt` is `Option<String>` (ISO-8601) rather than a
/// `DateTime` to avoid pulling in `chrono`; fulltext never sets it.
#[derive(Debug, Clone)]
pub struct Book {
    pub id: i64,
    pub title: String,
    pub hash: Option<String>,
    pub href: Option<String>,
    pub author: Option<String>,
    pub cover: Option<String>,
    pub description: Option<String>,
    pub publisher: Option<String>,
    pub year: Option<i64>,
    pub language: Option<String>,
    pub categories: Option<String>,
    pub pages: Option<i64>,
    pub series: Option<String>,
    pub extension: Option<String>,
    pub filesize: Option<i64>,
    pub filesize_string: Option<String>,
    pub interest_score: Option<String>,
    pub read_online_url: Option<String>,
    pub volume: Option<String>,
    pub isbn10: Option<String>,
    pub isbn13: Option<String>,
    pub ipfs_cid: Option<String>,
    pub ipfs_cid_blake2b: Option<String>,
    pub rating_interest: Option<String>,
    pub rating_quality: Option<String>,
    pub readlist_book_id: Option<i64>,
    pub note: Option<String>,
    pub downloaded_at: Option<String>,
}

/// One highlighted (or plain) run inside a [`FullTextHit`] snippet.
///
/// Mirrors `FullTextSnippetPart` in `fulltext.dart`.
#[derive(Debug, Clone)]
pub struct FullTextSnippetPart {
    pub text: String,
    pub highlighted: bool,
}

/// One full-text search hit: the book plus the matching passage.
///
/// Mirrors `FullTextHit` in `fulltext.dart`.
#[derive(Debug, Clone)]
pub struct FullTextHit {
    pub book: Book,
    pub snippet: Vec<FullTextSnippetPart>,
    pub removed: bool,
    pub unavailable_reason: Option<String>,
}

/// One page of full-text search results.
///
/// Mirrors `FullTextSearchPage` in `fulltext.dart`.
#[derive(Debug, Clone)]
pub struct FullTextSearchPage {
    pub hits: Vec<FullTextHit>,
    pub total: i64,
    pub total_pages: i64,
}

/// One article search hit (the site's 文章 tab). Mirrors `Article`
/// in `article_search.dart` — a dedicated model on purpose: the card
/// carries fields Book has no slot for (`download_path`, `quality`).
#[derive(Debug, Clone)]
pub struct Article {
    pub id: i64,
    pub title: String,
    pub href: Option<String>,
    pub url: Option<String>,
    pub hash: Option<String>,
    pub author: Option<String>,
    pub cover: Option<String>,
    pub publisher: Option<String>,
    pub year: Option<i64>,
    pub language: Option<String>,
    pub extension: Option<String>,
    pub filesize_string: Option<String>,
    pub rating: Option<String>,
    pub quality: Option<String>,
    pub download_path: Option<String>,
    pub removed: bool,
    pub unavailable_reason: Option<String>,
}

/// One page of article search results. Mirrors `ArticleSearchPage`.
#[derive(Debug, Clone)]
pub struct ArticleSearchPage {
    pub articles: Vec<Article>,
    pub total: i64,
    pub total_pages: i64,
}

/// Metadata parsed from a book detail page's HTML. Mirrors
/// `BookDetailMetadata` in `book_detail_html.dart` (all fields
/// `Option<String>`; missing rows parse to None).
#[derive(Debug, Clone)]
pub struct BookDetailMetadata {
    pub volume: Option<String>,
    pub isbn10: Option<String>,
    pub isbn13: Option<String>,
    pub ipfs_cid: Option<String>,
    pub ipfs_cid_blake2b: Option<String>,
    pub rating_interest: Option<String>,
    pub rating_quality: Option<String>,
}

/// One Z-Library booklist. Mirrors `Booklist` in `booklist.dart`.
/// NOTE: `id` is a String (numeric id attribute or the href's
/// booklists/booklist segment) — not an int, matching Dart.
#[derive(Debug, Clone)]
pub struct Booklist {
    pub id: String,
    pub name: String,
    pub description: String,
    pub author: String,
    pub author_profile: String,
    pub author_avatar: String,
    pub count: Option<i64>,
    pub views: String,
    pub comments: String,
    pub color: Option<i64>,
    pub is_private: bool,
    pub is_favorite: bool,
    pub cover_url: String,
    pub url: String,
    pub preview_books: Vec<Book>,
}

/// One page of booklist search results. Mirrors `BooklistsPage`
/// (total_pages is 0 when the page carried no page count).
#[derive(Debug, Clone)]
pub struct BooklistsPage {
    pub lists: Vec<Booklist>,
    pub total_pages: i64,
}

/// One book on a category page. Mirrors `CategoryBook`.
#[derive(Debug, Clone)]
pub struct CategoryBook {
    pub book: Book,
    pub is_favorite: bool,
    pub unavailable_reason: Option<String>,
}

/// One parsed category page. Mirrors `CategoryPage` — `total_pages`
/// is None when the page carries no inline pagerOptions (never
/// invent a total), unlike the fulltext/article parsers which
/// default to 1.
#[derive(Debug, Clone)]
pub struct CategoryPage {
    pub books: Vec<CategoryBook>,
    pub total_pages: Option<i64>,
    pub search_slug: Option<String>,
}

/// One search result or detail record from Anna's Archive.
/// Mirrors `ArchiveBook`.
#[derive(Debug, Clone)]
pub struct ArchiveBook {
    pub title: String,
    pub author: Option<String>,
    pub thumbnail: Option<String>,
    pub link: String,
    pub md5: String,
    pub publisher: Option<String>,
    pub info: Option<String>,
}

/// A parsed `/md5/<md5>` detail page. Mirrors `ArchiveBookDetails`
/// (fields flattened — no inheritance in the Rust model).
#[derive(Debug, Clone)]
pub struct ArchiveBookDetails {
    pub title: String,
    pub author: Option<String>,
    pub thumbnail: Option<String>,
    pub link: String,
    pub md5: String,
    pub publisher: Option<String>,
    pub info: Option<String>,
    pub description: Option<String>,
    pub slow_download_url: Option<String>,
}

/// One Library Genesis result. Mirrors `BookData` in
/// lib/services/annas_models.dart (the libgen parser fills the same
/// seven fields; `source` is set by the caller, not the parser).
#[derive(Debug, Clone)]
pub struct LibgenBookData {
    pub title: String,
    pub author: Option<String>,
    pub thumbnail: Option<String>,
    pub link: String,
    pub md5: String,
    pub publisher: Option<String>,
    pub info: Option<String>,
}

/// One parsed libgen `ads.php` page. Mirrors `BookInfoData`
/// (flattened; isFastDownload is caller-set, not parsed).
#[derive(Debug, Clone)]
pub struct LibgenBookInfoData {
    pub title: String,
    pub author: Option<String>,
    pub thumbnail: Option<String>,
    pub publisher: Option<String>,
    pub info: Option<String>,
    pub link: String,
    pub md5: String,
    pub format: String,
    pub mirror: Option<String>,
    pub description: Option<String>,
}

/// One Open Library trending row. Mirrors `TrendingBookData`
/// (title/thumbnail both Option — rows missing either are skipped).
#[derive(Debug, Clone)]
pub struct TrendingBookData {
    pub title: Option<String>,
    pub thumbnail: Option<String>,
}
