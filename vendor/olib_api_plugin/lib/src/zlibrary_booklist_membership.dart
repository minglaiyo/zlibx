// Booklist membership endpoints of [ZLibraryApi]: adding a book
// to a list, resolving the readlist membership-row id, and
// removing a book from a list. Split out of
// `zlibrary_booklists.dart` (review-2 P1-4) as a mixin in the
// same library, `on ZLibraryApiBase`, so it can use the base
// class's private HTTP helpers (`_getWithRedirects`,
// `_getDestructive`) directly. A mixin in a separate library
// could not see those privates without changing the public
// interface (which the six test fakes implement).
part of 'zlibrary_api.dart';

/// Booklist membership methods for [ZLibraryApi].
mixin ZLibraryBooklistMembership on ZLibraryApiBase {
  /// Add a book to one of the signed-in user's booklists:
  /// `GET /papi/booklist/{booklistId}/add-book/{bookId}`, confirmed
  /// by a packet capture on 2026-11-09 (Firefox, zh.z-library.sk):
  /// HTTP 200 with `{"success": 1, "book": {"readlist_id": 4090055, "book_id": "18337950", "date": "2026-11-09T08:04:24.000000Z"}}`.
  /// No request body (GET). This endpoint only adds: the site calls
  /// [removeBookFromBooklist] when the filled bookmark in a list's
  /// submenu is clicked again — it is NOT a toggle.
  Future<ApiResponse<bool>> addBookToBooklist({
    required int booklistId,
    required int bookId,
  }) async {
    final response = await addBookToBooklistEntry(
      booklistId: booklistId,
      bookId: bookId,
    );
    if (!response.success) {
      return ApiResponse.fail(
        response.error ?? 'add to booklist failed',
        statusCode: response.statusCode,
      );
    }
    return ApiResponse.ok(true);
  }

  /// Same call as [addBookToBooklist], but returns the readlist ENTRY
  /// id of the new membership row (what [removeBookFromBooklist]
  /// takes) instead of a bare success flag. The entry id is read from
  /// the response's `book` map as `readlist_id` first, else `id`:
  /// which field carries it is UNCONFIRMED — the 2026-11-09 capture
  /// showed `readlist_id`, the site's own picker reads `book.id`, so
  /// both are accepted. Null when the response carries neither (the
  /// add still succeeded; the caller can resolve the id later via
  /// [getReadlistBookId]).
  Future<ApiResponse<int?>> addBookToBooklistEntry({
    required int booklistId,
    required int bookId,
  }) async {
    final raw = await _getWithRedirects(
      '/papi/booklist/$booklistId/add-book/$bookId',
    );
    if (raw.json == null) {
      return ApiResponse.fail(
        raw.error ?? 'add to booklist failed',
        statusCode: raw.status,
      );
    }
    final json = raw.json!;
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'add to booklist failed',
        ),
        statusCode: raw.status,
      );
    }
    final book = json['book'];
    final entryId = book is Map<String, dynamic>
        ? _asInt(book['readlist_id'] ?? book['id'])
        : null;
    return ApiResponse.ok(entryId);
  }

  /// All of the signed-in user's booklists plus whether [bookId] is in
  /// each: `GET /papi/booklist/current-user/{bookId}`, the same call
  /// [getReadlistBookId] uses for one list. The site's add-to-booklist
  /// picker renders this whole table (member flags, local search,
  /// inline create). Returns the entries in the server's order.
  Future<ApiResponse<List<BooklistMembership>>> getBooklistsForBook(
    int bookId,
  ) async {
    final raw = await _getWithRedirects(
      '/papi/booklist/current-user/$bookId',
    );
    final json = raw.json;
    if (json == null) {
      return ApiResponse.fail(
        raw.error ?? 'get booklists failed',
        statusCode: raw.status,
      );
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'get booklists failed',
        ),
        statusCode: raw.status,
      );
    }
    final list = json['list'];
    if (list is! List) {
      return ApiResponse.fail(
        'get booklists failed',
        statusCode: raw.status,
      );
    }
    final memberships = <BooklistMembership>[];
    for (final entry in list) {
      if (entry is! Map<String, dynamic>) continue;
      final id = _asInt(entry['id']);
      if (id == null) continue;
      memberships.add(
        BooklistMembership(
          booklistId: id,
          title: entry['title']?.toString() ?? '',
          readlistBookId: _asInt(entry['readlistBookId']),
        ),
      );
    }
    return ApiResponse.ok(memberships);
  }

  /// Coerce an int-or-numeric-string JSON value, null otherwise.
  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Resolve the readlist ENTRY id for one (book, booklist) pair:
  /// `GET /papi/booklist/current-user/{bookId}`, confirmed by a
  /// packet capture on 2026-11-09 (Firefox, zh.z-library.sk): the
  /// detail page of 白鹿原 (book 11959979) loads this URL on page load
  /// and it answers `{"success": 1, "list": [...]}` with one entry
  /// per list the signed-in user owns. Each entry carries the list
  /// `id` plus `readlistBookId` — the per-(book, list) membership-row
  /// id, null when the book is not in that list (白鹿原 in 001:
  /// `readlistBookId` 161213534; in 嘎嘎嘎 and 555: null).
  ///
  /// Returns the entry id for the target list, or null when the book
  /// is not in that list (or the list is absent from the response).
  /// [removeBookFromBooklist] takes this entry id, NOT the book id —
  /// sending the book id there is what the server 500s on.
  Future<ApiResponse<int?>> getReadlistBookId({
    required int booklistId,
    required int bookId,
  }) async {
    final raw = await _getWithRedirects(
      '/papi/booklist/current-user/$bookId',
    );
    final json = raw.json;
    if (json == null) {
      return ApiResponse.fail(
        raw.error ?? 'get booklist entry failed',
        statusCode: raw.status,
      );
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'get booklist entry failed',
        ),
        statusCode: raw.status,
      );
    }
    final list = json['list'];
    if (list is! List) {
      return ApiResponse.fail(
        'get booklist entry failed',
        statusCode: raw.status,
      );
    }
    for (final entry in list) {
      if (entry is! Map<String, dynamic>) continue;
      if (_asInt(entry['id']) != booklistId) continue;
      return ApiResponse.ok(_asInt(entry['readlistBookId']));
    }
    return ApiResponse.ok(null);
  }

  /// Remove a book from one of the signed-in user's booklists:
  /// `GET /papi/booklist/{booklistId}/remove-book/{readlistBookId}`,
  /// confirmed by a packet capture on 2026-11-09 (Firefox,
  /// zh.z-library.sk): list 4096101, entry 161286730, HTTP 200 with
  /// `{"success": 1}`. No request body (GET). This is a separate
  /// endpoint, NOT a toggle of [addBookToBooklist] — the site calls it
  /// when the filled bookmark in a list's submenu is clicked again.
  ///
  /// [readlistBookId] is the per-(book, list) membership-row id from
  /// [getReadlistBookId], NOT the book id: the website's own remove
  /// for 嘎嘎嘎 sent 161286730 while the removed book's id is in the
  /// 5–21M range, and 白鹿原 (book 11959979) in 001 carries
  /// `readlistBookId` 161213534. Sending the book id here is what the
  /// server answers with a generic 500 for every app remove, while
  /// the website remove succeeds.
  Future<ApiResponse<bool>> removeBookFromBooklist({
    required int booklistId,
    required int readlistBookId,
  }) async {
    // Plan item 5: a destructive GET goes through the dedicated
    // no-retry, no-redirect client — never the redirect-following one.
    final raw = await _getDestructive(
      '/papi/booklist/$booklistId/remove-book/$readlistBookId',
    );
    final status = raw.status;
    final json = raw.json;
    if (json == null) {
      // Same precedent as [deleteBooklist]: a final 2xx with an empty
      // body counts as removed; anything else without JSON (a wall, a
      // transport error, a non-2xx status) is a failure.
      final is2xx = status != null && status >= 200 && status < 300;
      final emptyBody = raw.body == null &&
          (raw.error?.startsWith('empty response') ?? false);
      if (is2xx && emptyBody) {
        return ApiResponse.ok(true);
      }
      return ApiResponse.fail(
        raw.error ?? 'remove from booklist failed',
        statusCode: status,
      );
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'remove from booklist failed',
        ),
        statusCode: status,
      );
    }
    return ApiResponse.ok(true);
  }
}
