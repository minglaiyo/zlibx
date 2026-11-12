/// One book as returned by the Z-Library eapi.
///
/// Only `id` and `title` are required: the app itself constructs minimal
/// [Book] objects from download history with just `id`, `title`, `author`,
/// `cover` and `extension`. Every other field is nullable because list
/// responses omit fields that detail responses include (and vice versa).
///
/// `fromJson` accepts both camelCase and snake_case keys, and coerces
/// int/string mismatches, because the eapi is not formally documented and
/// different endpoints spell the same field differently.
class Book {
  final int id;
  final String title;
  final String? hash;

  /// The book's webpage path (`/book/{hash}/{slug}.html`) when a list
  /// response carried it. Kept so the detail screen can fetch the
  /// detail HTML for the metadata below; the eapi detail response does
  /// not include it.
  final String? href;
  final String? author;
  final String? cover;
  final String? description;
  final String? publisher;
  final int? year;
  final String? language;

  /// Website category, e.g. "Fiction - Horror" (eapi `categories`).
  /// Present only when the detail response carries it — not every book
  /// has one, so the detail page shows the chip only when non-empty.
  final String? categories;
  final int? pages;
  final String? series;
  final String? extension;

  /// Raw size in bytes, when the server (or the app, for LAN imports)
  /// provides it. [filesizeString] is the display form.
  final int? filesize;
  final String? filesizeString;
  final String? interestScore;
  final String? readOnlineUrl;

  /// Detail-page-only metadata (NOT in the eapi book object): parsed
  /// from the book detail HTML (`property_volume` / `property_isbn_13` /
  /// `property_isbn_10` / `property_ipfs_cid` rows — see
  /// `parseBookDetailProperties`). Null when the HTML row was absent or
  /// the HTML fetch was skipped/failed.
  final String? volume;
  final String? isbn10;
  final String? isbn13;
  final String? ipfsCid;
  final String? ipfsCidBlake2b;

  /// Detail-page-only rating (NOT in the eapi book object): the
  /// community interest / quality scores rendered in the page header
  /// (`book-rating-interest-score` / `book-rating-quality-score`
  /// spans — see `parseBookDetailProperties`). Rendered strings
  /// (`3.0`); null when the page hides the span (unrated book) or the
  /// HTML fetch was skipped/failed. Distinct from [interestScore]:
  /// that one comes from eapi/search payloads, these two only ever
  /// come from the detail page.
  final String? ratingInterest;
  final String? ratingQuality;

  /// When this download happened (per-download record from the site's
  /// `/users/downloads` history page — see `parseDownloadStatsPage`). The
  /// eapi book object carries no download timestamp, so this stays
  /// null for books coming from search / saved / the eapi downloaded
  /// list; the cloud-history screen shows it when present.
  final DateTime? downloadedAt;

  /// Booklist-detail-only fields (NOT in the eapi book object): the
  /// readlist membership-row id (`booklistsindex` attribute) and the
  /// per-book note (`div[slot="note"]`) of a `<z-bookcard>` on a
  /// booklist detail page — see `parseBooklistDetailBooks`. Null when
  /// the book did not come from a booklist detail page. The entry id
  /// is what remove-book and save-description take, never the book id.
  final int? readlistBookId;
  final String? note;

  const Book({
    required this.id,
    required this.title,
    this.hash,
    this.href,
    this.author,
    this.cover,
    this.description,
    this.publisher,
    this.year,
    this.language,
    this.categories,
    this.pages,
    this.series,
    this.extension,
    this.filesize,
    this.filesizeString,
    this.interestScore,
    this.readOnlineUrl,
    this.volume,
    this.isbn10,
    this.isbn13,
    this.ipfsCid,
    this.ipfsCidBlake2b,
    this.ratingInterest,
    this.ratingQuality,
    this.readlistBookId,
    this.note,
    this.downloadedAt,
  });

  factory Book.fromJson(Map<String, dynamic> json) {
    // The get-books JSON carries no `hash`, but its `href` does:
    // `/book/{hash}/{slug}.html`. The detail screen needs the hash
    // (`GET /eapi/book/{id}/{hash}`), so derive it when absent.
    final href = _asString(json['href']);
    return Book(
      id: _asInt(json['id']) ?? 0,
      title: _asString(json['title']) ?? '',
      // An EMPTY hash string must not shadow the href fallback below:
      // `hash: ""` would produce `/eapi/book/{id}/` requests that only
      // the expensive resolveEapiHash search could ever repair.
      hash: _nonEmptyString(json['hash'] ?? json['hashId']) ??
          hashFromBookHref(href),
      href: _nonEmptyString(href),
      author: _joinAuthor(json['author']),
      cover: _asString(json['cover']),
      description: _asString(json['description']),
      publisher: _asString(json['publisher']),
      year: _asInt(json['year']),
      language: _asString(json['language']),
      categories: _joinCategories(json['categories']),
      pages: _asInt(json['pages']),
      series: _asString(json['series']),
      extension: _asString(json['extension']),
      filesize: _asInt(json['filesize']),
      filesizeString: _filesizeString(json),
      interestScore: _asString(
        json['interestScore'] ??
            json['interest_score'] ??
            json['qualityScore'],
      ),
      readOnlineUrl: _asString(
        json['readOnlineUrl'] ?? json['read_online_url'],
      ),
      // Defensive only: the eapi book object does not carry these
      // (they live in the detail HTML), but map them if a future
      // endpoint ever does.
      volume: _nonEmptyString(json['volume']),
      isbn10: _nonEmptyString(json['isbn10'] ?? json['isbn_10']),
      isbn13: _nonEmptyString(json['isbn13'] ?? json['isbn_13']),
      ipfsCid: _nonEmptyString(json['ipfsCid'] ?? json['ipfs_cid']),
      ipfsCidBlake2b: _nonEmptyString(
        json['ipfsCidBlake2b'] ?? json['ipfs_cid_blake2b'],
      ),
      readlistBookId: _asInt(
        json['readlistBookId'] ?? json['readlist_book_id'],
      ),
      note: _nonEmptyString(json['note']),
      downloadedAt: _asDateTime(
        json['downloadedAt'] ?? json['downloaded_at'],
      ),
    );
  }

  /// Book hash from a `/book/{hash}/{slug}.html` href, or null when the
  /// href does not have that shape. Public because the dstats history
  /// parser (download_stats.dart) builds [Book]s from the same
  /// `/book/{hash}/…` links the list JSON carries.
  static String? hashFromBookHref(String? href) {
    if (href == null || href.isEmpty) return null;
    final segments = Uri.tryParse(href)?.pathSegments ?? const <String>[];
    if (segments.length >= 2 && segments[0] == 'book') {
      final hash = segments[1];
      return hash.isEmpty ? null : hash;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (hash != null) 'hash': hash,
    if (href != null) 'href': href,
    if (author != null) 'author': author,
    if (cover != null) 'cover': cover,
    if (description != null) 'description': description,
    if (publisher != null) 'publisher': publisher,
    if (year != null) 'year': year,
    if (language != null) 'language': language,
    if (categories != null) 'categories': categories,
    if (pages != null) 'pages': pages,
    if (series != null) 'series': series,
    if (extension != null) 'extension': extension,
    if (filesize != null) 'filesize': filesize,
    if (filesizeString != null) 'filesizeString': filesizeString,
    if (interestScore != null) 'interestScore': interestScore,
    if (readOnlineUrl != null) 'readOnlineUrl': readOnlineUrl,
    if (volume != null) 'volume': volume,
    if (isbn10 != null) 'isbn10': isbn10,
    if (isbn13 != null) 'isbn13': isbn13,
    if (ipfsCid != null) 'ipfsCid': ipfsCid,
    if (ipfsCidBlake2b != null) 'ipfsCidBlake2b': ipfsCidBlake2b,
    if (readlistBookId != null) 'readlistBookId': readlistBookId,
    if (note != null) 'note': note,
    if (downloadedAt != null) 'downloadedAt': downloadedAt!.toIso8601String(),
  };

  /// Copy with overrides. A null argument keeps the current value
  /// (there is no need to clear a field back to null anywhere in the
  /// app); this is what lets the detail provider merge HTML-parsed
  /// metadata into the eapi book.
  Book copyWith({
    int? id,
    String? title,
    String? hash,
    String? href,
    String? author,
    String? cover,
    String? description,
    String? publisher,
    int? year,
    String? language,
    String? categories,
    int? pages,
    String? series,
    String? extension,
    int? filesize,
    String? filesizeString,
    String? interestScore,
    String? readOnlineUrl,
    String? volume,
    String? isbn10,
    String? isbn13,
    String? ipfsCid,
    String? ipfsCidBlake2b,
    String? ratingInterest,
    String? ratingQuality,
    int? readlistBookId,
    String? note,
    DateTime? downloadedAt,
  }) {
    return Book(
      id: id ?? this.id,
      title: title ?? this.title,
      hash: hash ?? this.hash,
      href: href ?? this.href,
      author: author ?? this.author,
      cover: cover ?? this.cover,
      description: description ?? this.description,
      publisher: publisher ?? this.publisher,
      year: year ?? this.year,
      language: language ?? this.language,
      categories: categories ?? this.categories,
      pages: pages ?? this.pages,
      series: series ?? this.series,
      extension: extension ?? this.extension,
      filesize: filesize ?? this.filesize,
      filesizeString: filesizeString ?? this.filesizeString,
      interestScore: interestScore ?? this.interestScore,
      readOnlineUrl: readOnlineUrl ?? this.readOnlineUrl,
      volume: volume ?? this.volume,
      isbn10: isbn10 ?? this.isbn10,
      isbn13: isbn13 ?? this.isbn13,
      ipfsCid: ipfsCid ?? this.ipfsCid,
      ipfsCidBlake2b: ipfsCidBlake2b ?? this.ipfsCidBlake2b,
      ratingInterest: ratingInterest ?? this.ratingInterest,
      ratingQuality: ratingQuality ?? this.ratingQuality,
      readlistBookId: readlistBookId ?? this.readlistBookId,
      note: note ?? this.note,
      downloadedAt: downloadedAt ?? this.downloadedAt,
    );
  }

  static int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString());
  }

  static String? _asString(dynamic v) {
    if (v == null) return null;
    if (v is String) return v;
    return v.toString();
  }

  static String? _joinAuthor(dynamic v) {
    if (v == null) return null;
    if (v is List) {
      return v.map((e) => e.toString()).where((e) => e.isNotEmpty).join(', ');
    }
    return _asString(v);
  }

  /// Categories arrive as one string ("Fiction - Horror") in the eapi
  /// detail response; a list form is joined the same way as authors.
  static String? _joinCategories(dynamic v) {
    if (v == null) return null;
    if (v is List) {
      final parts =
          v.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
      return parts.isEmpty ? null : parts.join(', ');
    }
    final text = _asString(v);
    return text == null || text.isEmpty ? null : text;
  }

  static String? _filesizeString(Map<String, dynamic> json) {
    final direct = _asString(
      json['filesizeString'] ?? json['filesize_string'],
    );
    if (direct != null) return direct;
    final bytes = _asInt(json['filesize']);
    if (bytes == null) return null;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// [_asString] with empty-string normalization: many endpoints return
  /// `""` instead of omitting optional fields, and an empty value must
  /// behave like an absent one.
  static String? _nonEmptyString(dynamic v) {
    final s = _asString(v);
    return (s == null || s.isEmpty) ? null : s;
  }

  /// ISO-8601 string or epoch milliseconds/seconds — the forms a
  /// [toJson]/server round-trip produces. Null (or unparsable) stays
  /// null: an absent timestamp must never read as "now" or epoch 0.
  static DateTime? _asDateTime(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is num) {
      // 10-digit = seconds, 13+ digits = milliseconds; anything else is
      // not a timestamp this model understands.
      if (v <= 0) return null;
      if (v >= 100000000000000) return null;
      final ms = v >= 100000000000 ? v.toInt() : v.toInt() * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    final s = v.toString();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s);
  }
}
