// Booklist write endpoints of [ZLibraryApi]: create / edit /
// delete lists, colour / visibility / favourite toggles and the
// per-book note. Split out of `zlibrary_booklists.dart`
// (review-2 P1-4) as a mixin in the same library, `on
// ZLibraryApiBase`, so it can use the base class's private HTTP
// helpers (`_postText`, `_getWithRedirects`, `_getDestructive`,
// `_delete`) directly. A mixin in a separate library could not
// see those privates without changing the public interface
// (which the six test fakes implement).
part of 'zlibrary_api.dart';

/// Booklist write methods for [ZLibraryApi].
mixin ZLibraryBooklistWrites on ZLibraryApiBase {
  /// Create a booklist owned by the signed-in user. `POST
  /// /papi/booklist/create` with a JSON body `{title, description}`
  /// sent as `text/plain` (the same transport as postBookComment,
  /// so redirects are followed). Request shape taken from a browser
  /// capture on 2026-11-07 (Firefox, zh.z-library.sk), which showed no
  /// response data: the site answers with an empty body, so a 2xx
  /// with an empty body is success.
  ///
  /// A JSON answer is still handled leniently in case the site starts
  /// returning one: an explicit failure flag or an `error`/`message`
  /// field fails the call, otherwise it counts as created.
  /// [ApiResponse.data] is the new list when the JSON answer carries
  /// it (the site's form reads `response.readlist`), and null when the
  /// answer is an empty body — callers must not depend on it and
  /// should reload the "my booklists" page after a successful create
  /// when it is null.
  ///
  /// The site's form also sends the optional [color] (0–5), [isPrivate]
  /// and [bookId] ("create and add this book in one call", used by the
  /// add-to-booklist picker's inline create): they are included in the
  /// body only when given. The create answer is `{readlist: {id,
  /// title, hash, …}}` per the site's own form handler — see
  /// [_booklistFromCreateResponse].
  Future<ApiResponse<Booklist?>> createBooklist({
    required String title,
    String description = '',
    int? color,
    bool? isPrivate,
    int? bookId,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      return ApiResponse.fail('booklist title is empty');
    }
    final body = <String, dynamic>{
      'title': cleanTitle,
      'description': description.trim(),
      if (color != null) 'color': color,
      if (isPrivate != null) 'private': isPrivate,
      if (bookId != null) 'bookId': bookId,
    };
    final raw = await _postText(
      '/papi/booklist/create',
      jsonEncode(body),
    );
    final status = raw.status;
    final json = raw.json;
    if (json == null) {
      // The create call answers with an EMPTY body (confirmed by the
      // 2026-11-07 capture: no response data), so a 2xx with no body
      // is the success case. [_fromResponse] marks it with an
      // 'empty response' error and leaves [_Raw.body] null. Anything
      // else without JSON (a non-JSON page, a wall, a transport error,
      // a non-2xx status) is a failure and keeps its real cause.
      final is2xx = status != null && status >= 200 && status < 300;
      final emptyBody = raw.body == null &&
          (raw.error?.startsWith('empty response') ?? false);
      if (is2xx && emptyBody) {
        return ApiResponse.ok(null);
      }
      return ApiResponse.fail(
        raw.error ?? 'create booklist failed',
        statusCode: status,
      );
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'create booklist failed',
        ),
        statusCode: status,
      );
    }
    return ApiResponse.ok(_booklistFromCreateResponse(json, cleanTitle));
  }

  /// Delete one of the signed-in user's booklists:
  /// `GET /papi/booklist/{booklistId}/delete`, confirmed by a packet
  /// capture on 2026-11-09 (Firefox, zh.z-library.sk). The first
  /// response is 307 to the same URL with a `__diamwall` set-cookie
  /// (the DDoS-Guard challenge, not delete logic); the list was gone
  /// from the profile BOOKLISTS tab afterwards, so the delete itself
  /// succeeded. The final response body after following the redirect
  /// was never observed, so a non-JSON 2xx final response counts as
  /// success only when it is an empty body (same precedent as
  /// [createBooklist]) — an HTML final page fails instead.
  Future<ApiResponse<bool>> deleteBooklist(int booklistId) async {
    // Plan item 5: a destructive GET goes through the dedicated
    // no-retry, no-redirect client. The challenge hop it answers
    // with (307 + `__diamwall`, same URL) is the one redirect the
    // destructive client follows; anything else fails instead of
    // re-issuing the delete elsewhere.
    final raw = await _getDestructive('/papi/booklist/$booklistId/delete');
    final status = raw.status;
    final json = raw.json;
    if (json == null) {
      final is2xx = status != null && status >= 200 && status < 300;
      final emptyBody = raw.body == null &&
          (raw.error?.startsWith('empty response') ?? false);
      if (is2xx && emptyBody) {
        return ApiResponse.ok(true);
      }
      return ApiResponse.fail(
        raw.error ?? 'delete booklist failed',
        statusCode: status,
      );
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'delete booklist failed',
        ),
        statusCode: status,
      );
    }
    return ApiResponse.ok(true);
  }

  /// Edit one of the signed-in user's booklists: `POST
  /// /papi/booklist/{id}/edit` with `{title, description, private,
  /// color}` (the site's `#readlistForm` in edit mode). The answer
  /// carries the updated list as `{readlist: {...}}` — parsed the same
  /// way as a create answer. [ApiResponse.data] is the updated list,
  /// or null when the answer was an empty body (same lenient read as
  /// [createBooklist]).
  Future<ApiResponse<Booklist?>> editBooklist({
    required int id,
    required String title,
    String description = '',
    bool isPrivate = false,
    int? color,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      return ApiResponse.fail('booklist title is empty');
    }
    final body = <String, dynamic>{
      'title': cleanTitle,
      'description': description.trim(),
      'private': isPrivate,
      if (color != null) 'color': color,
    };
    final raw = await _postText(
      '/papi/booklist/$id/edit',
      jsonEncode(body),
    );
    final status = raw.status;
    final json = raw.json;
    if (json == null) {
      final is2xx = status != null && status >= 200 && status < 300;
      final emptyBody = raw.body == null &&
          (raw.error?.startsWith('empty response') ?? false);
      if (is2xx && emptyBody) {
        return ApiResponse.ok(null);
      }
      return ApiResponse.fail(
        raw.error ?? 'edit booklist failed',
        statusCode: status,
      );
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          'edit booklist failed',
        ),
        statusCode: status,
      );
    }
    return ApiResponse.ok(_booklistFromCreateResponse(json, cleanTitle));
  }

  /// Change one of the signed-in user's booklists' color: `GET
  /// /papi/booklist/{id}/color/{0..5}` (the site's "…" menu, color
  /// submenu). No request body; a 2xx (JSON success or empty body)
  /// counts as changed.
  Future<ApiResponse<bool>> setBooklistColor({
    required int id,
    required int color,
  }) async {
    final raw = await _getWithRedirects('/papi/booklist/$id/color/$color');
    return _boolFromWriteRaw(raw, 'change booklist color failed');
  }

  /// Flip one of the signed-in user's booklists between public and
  /// private: `GET /papi/booklist/{id}/public` (the site's "…" menu).
  /// No parameters — the server flips the current state. No request
  /// body; a 2xx (JSON success or empty body) counts as flipped. The
  /// new state is NOT in the response; callers reload or flip their
  /// local flag on success.
  Future<ApiResponse<bool>> toggleBooklistPublic(int id) async {
    final raw = await _getWithRedirects('/papi/booklist/$id/public');
    return _boolFromWriteRaw(raw, 'change booklist visibility failed');
  }

  /// Favorite a booklist (anyone's): `POST
  /// /papi/booklist/{id}/favorite/add` (the heart on the site's list
  /// card). The site sends no body; `'{}'` is posted to keep the
  /// JSON-string transport. A 2xx (JSON success or empty body) counts
  /// as favorited.
  Future<ApiResponse<bool>> favoriteBooklist(int id) async {
    final raw = await _postText('/papi/booklist/$id/favorite/add', '{}');
    return _boolFromWriteRaw(raw, 'favorite booklist failed');
  }

  /// Unfavorite a booklist: `DELETE
  /// /papi/booklist/{id}/favorite/remove` (the filled heart on the
  /// site's list card). No request body; a 2xx (JSON success or empty
  /// body) counts as unfavorited.
  Future<ApiResponse<bool>> unfavoriteBooklist(int id) async {
    final raw = await _delete('/papi/booklist/$id/favorite/remove');
    return _boolFromWriteRaw(raw, 'unfavorite booklist failed');
  }

  /// Save the per-book note inside one of the signed-in user's
  /// booklists: `POST /papi/booklist/{id}/save-description/{entryId}`
  /// with `{bookDescription}`. The site sends a single space for an
  /// empty note, so an empty [description] is sent as `' '` here too.
  /// [entryId] is the readlist membership-row id (the card's
  /// `booklistsindex`, see [Book.readlistBookId]), NOT the book id.
  Future<ApiResponse<bool>> saveBookDescription({
    required int listId,
    required int entryId,
    required String description,
  }) async {
    final raw = await _postText(
      '/papi/booklist/$listId/save-description/$entryId',
      jsonEncode({
        'bookDescription': description.isEmpty ? ' ' : description,
      }),
    );
    return _boolFromWriteRaw(raw, 'save book note failed');
  }

  /// Shared success read for the small write endpoints (color, public,
  /// favorite, save-description): a JSON `success: 1` wins; a final
  /// 2xx with an empty body counts as success (same precedent as
  /// [deleteBooklist]); anything else fails with its real cause.
  ApiResponse<bool> _boolFromWriteRaw(_Raw raw, String fallbackError) {
    final status = raw.status;
    final json = raw.json;
    if (json == null) {
      final is2xx = status != null && status >= 200 && status < 300;
      final emptyBody = raw.body == null &&
          (raw.error?.startsWith('empty response') ?? false);
      if (is2xx && emptyBody) {
        return ApiResponse.ok(true);
      }
      return ApiResponse.fail(raw.error ?? fallbackError, statusCode: status);
    }
    if (!ZLibraryApiBase._isSuccess(json)) {
      return ApiResponse.fail(
        ZLibraryApiBase._plainError(
          (json['error'] ?? json['message'])?.toString(),
          fallbackError,
        ),
        statusCode: status,
      );
    }
    return ApiResponse.ok(true);
  }

  /// Best-effort read of the list a create call returned. The site's
  /// form reads `response.readlist`, so that wrapper is tried first;
  /// the other wrappers are kept for a response shape that has not
  /// been seen yet. Needs a numeric `id` to count as a list. Returns
  /// null when nothing matches.
  Booklist? _booklistFromCreateResponse(
    Map<String, dynamic> json,
    String title,
  ) {
    for (final candidate in [
      json['readlist'],
      json['booklist'],
      json['list'],
      json['data'],
      json,
    ]) {
      if (candidate is! Map<String, dynamic>) continue;
      final id = candidate['id']?.toString() ?? '';
      if (!RegExp(r'^\d+$').hasMatch(id)) continue;
      final name = candidate['title']?.toString() ??
          candidate['topic']?.toString() ??
          title;
      return Booklist(
        id: id,
        name: name,
        description: candidate['description']?.toString() ?? '',
        count: 0,
        url: '$_base/booklist/$id',
      );
    }
    return null;
  }
}
