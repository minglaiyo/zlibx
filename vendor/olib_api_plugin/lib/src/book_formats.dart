// Per-format download references (plan item 2): one book, every format
// the server has for it, each with its own id:hash.
//
// `GET /eapi/book/{id}/{hash}/formats` answers with the formats the
// server has for this book — format + size, each carrying its own
// id:hash, so the app downloads that reference instead of the one on
// the detail page. No local conversion, no extension guessing.
//
// The non-empty envelope was never verified against a live account
// (qgming's own samples only ever came back empty), so the parser is
// defensive: it accepts the enveloped form
// (`{"success":1,"formats":[...]}` / `{"success":1,"data":[...]}`)
// and the bare form (the array itself), tolerates per-entry key
// variants, skips entries that cannot be used, and fails loudly when
// nothing usable survives — the app then offers the current format
// instead of pretending there are no other formats. An empty list is
// a success: the book simply has no other format.
part of 'zlibrary_api.dart';

/// One downloadable format of a book: its own id:hash reference plus
/// the extension and size for the picker.
class BookFormat {
  /// The format's own book id. It may differ from the detail page's
  /// id: each format is its own server record.
  final int id;

  /// The format's own eapi hash. The pair (id, hash) is what the file
  /// endpoint wants — the detail page's hash belongs to its own
  /// format.
  final String hash;

  /// Lowercased extension, e.g. `epub`.
  final String extension;

  /// Size in bytes when the server sent one.
  final int? filesize;

  /// Server-provided display size, e.g. `12.3 MB`.
  final String? filesizeString;

  const BookFormat({
    required this.id,
    required this.hash,
    required this.extension,
    this.filesize,
    this.filesizeString,
  });
}

/// Format-list methods for [ZLibraryApi].
mixin ZLibraryBookFormats on ZLibraryApiBase {
  /// `GET /eapi/book/{id}/{hash}/formats`: every format the server
  /// has for this book.
  ///
  /// A read-only lookup: it never touches a file endpoint and never
  /// spends download quota. Success with an empty list means the book
  /// has no other format — the caller downloads the current format.
  /// Any failure (transport, wall, or a shape the parser cannot use)
  /// is an [ApiResponse.fail] the caller must surface with a retry,
  /// never read as "no other formats".
  Future<ApiResponse<List<BookFormat>>> getBookFormats(
    String bookId,
    String hashId,
  ) async {
    // Direct Dio, not `_get`: `_get` drops non-Map JSON bodies, so a
    // bare-array answer would come back as 'unexpected response
    // format' with the list already lost. Same request shape as `_get`
    // otherwise (session headers, plain body, no redirect following).
    final Response<String> res;
    try {
      res = await _dio.get<String>(
        '$_base/eapi/book/$bookId/$hashId/formats',
        options: Options(
          headers: _headers,
          responseType: ResponseType.plain,
          followRedirects: false,
        ),
      );
    } on DioException catch (e) {
      final raw = _fromError(e);
      return ApiResponse.fail(
        raw.error ?? 'formats request failed',
        statusCode: raw.status,
      );
    }
    final body = res.data ?? '';
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return ApiResponse.fail(
        'unexpected response format',
        statusCode: res.statusCode,
      );
    }
    final formats = _formatsOf(decoded);
    if (formats == null) {
      return ApiResponse.fail(
        'unexpected response format',
        statusCode: res.statusCode,
      );
    }
    return ApiResponse.ok(formats);
  }

  /// The formats list inside [decoded], or null when the shape cannot
  /// be used at all. A `success: 0` envelope fails; an envelope
  /// without a list fails; a bare array is the list itself.
  static List<BookFormat>? _formatsOf(dynamic decoded) {
    final List<dynamic> rawList;
    if (decoded is List) {
      rawList = decoded;
    } else if (decoded is Map<String, dynamic>) {
      if (!_isSuccess(decoded)) return null;
      final raw = decoded['formats'] ?? decoded['data'];
      if (raw is! List) return null;
      rawList = raw;
    } else {
      return null;
    }
    final formats = <BookFormat>[];
    for (final entry in rawList) {
      final format = _formatOf(entry);
      if (format != null) formats.add(format);
    }
    // A non-empty list with no usable entry is a shape mismatch, not
    // an empty book: fail so the caller offers a retry instead of
    // silently downloading the current format.
    if (rawList.isNotEmpty && formats.isEmpty) return null;
    return formats;
  }

  /// One list entry → [BookFormat], or null when it cannot be used
  /// for a download (no extension, no id, or no hash). Key variants
  /// are tolerated because the entry shape was never verified.
  static BookFormat? _formatOf(dynamic entry) {
    if (entry is! Map) return null;
    final extension = _formatString(
      entry['extension'] ?? entry['ext'] ?? entry['format'],
    )?.trim().toLowerCase();
    if (extension == null || extension.isEmpty) return null;
    final id = _formatInt(entry['id'] ?? entry['bookId'] ?? entry['book_id']);
    if (id == null || id <= 0) return null;
    final hash = _formatString(
      entry['hash'] ?? entry['hashId'] ?? entry['hash_id'],
    )?.trim();
    if (hash == null || hash.isEmpty) return null;
    final filesize = _formatInt(entry['filesize'] ?? entry['size']);
    final filesizeString = _formatString(
      entry['filesizeString'] ??
          entry['filesize_string'] ??
          entry['sizeString'],
    )?.trim();
    return BookFormat(
      id: id,
      hash: hash,
      extension: extension,
      filesize: filesize,
      filesizeString: (filesizeString == null || filesizeString.isEmpty)
          ? null
          : filesizeString,
    );
  }

  static int? _formatInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString());
  }

  static String? _formatString(dynamic v) {
    if (v == null) return null;
    if (v is String) return v;
    return v.toString();
  }
}
