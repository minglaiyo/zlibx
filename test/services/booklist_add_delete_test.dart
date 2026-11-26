import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

// Booklist add/remove/delete endpoint tests, all confirmed by packet
// captures on 2026-11-09 (Firefox, zh.z-library.sk):
// - Add: `GET /papi/booklist/{booklistId}/add-book/{bookId}`, HTTP 200
//   with `{"success": 1, "book": {"readlist_id": <booklistId>,
//   "book_id": "<bookId>", "date": "..."}}`. No request body (GET).
// - Remove: `GET /papi/booklist/{booklistId}/remove-book/{readlistBookId}`,
//   HTTP 200 with `{"success": 1}`. No request body (GET). A separate
//   endpoint, NOT a toggle of add-book. The id is the readlist ENTRY id
//   (the per-(book, list) membership-row id), NOT the book id: the
//   website's own remove for list 4096101 sent 161286730, and 白鹿原
//   (book 11959979) in 001 carries `readlistBookId` 161213534.
// - Entry id: `GET /papi/booklist/current-user/{bookId}`, HTTP 200
//   with `{"success": 1, "list": [...]}`; each entry carries the list
//   `id` plus `readlistBookId` (null when the book is not in that list).
// - Delete: `GET /papi/booklist/{booklistId}/delete`. The first
//   response is 307 to the same URL with a `__diamwall` set-cookie
//   (the DDoS-Guard challenge); the list was gone from the profile
//   BOOKLISTS tab afterwards. The final response body was never
//   observed, so the implementation counts a final 2xx with an empty
//   body as success (same precedent as createBooklist) and a final
//   JSON body must carry success: 1.
//
// Redirect-cookie regression tests (2026-11-09 capture, item: hop
// set-cookie was dropped): the fake can answer the first delete /
// comment-like / comment-delete hop with a `__diamwall` set-cookie and
// records every request's headers, pinning that the follow-up request
// carries the learned cookie next to the session pair, and that a
// cross-host target hop learns nothing and drops the Cookie header as
// before.

const _booklistId = 4090055;
const _bookId = 18337950;
const _addPath = '/papi/booklist/$_booklistId/add-book/$_bookId';
const _removeListId = 4096101;
const _removeEntryId = 161286730;
const _removePath =
    '/papi/booklist/$_removeListId/remove-book/$_removeEntryId';
const _currentUserBookId = 11959979;
const _currentUserPath = '/papi/booklist/current-user/$_currentUserBookId';
const _currentUserListId = 4088695;
const _currentUserEntryId = 161213534;
// Session + profile: loginWithToken validates against /eapi/user/profile
// before the redirect-cookie tests can assert on Cookie headers.
const _sessionUserId = '35899435';
const _sessionUserKey = 'sessionkey-abc123';
const _profilePath = '/eapi/user/profile';
// Comment like: the POST side of the redirect-cookie fix (`_postText`),
// 307 to the same URL like the 2026-11-06 capture.
const _likeCommentId = 1046367;
const _likePath = '/papi/comments/like/$_likeCommentId/1';
// Comment delete: the DELETE side (`_delete`), same wall, same fix —
// the 2026-11-09 capture answered 200 directly, no 307 seen yet.
const _commentDeleteId = 1046367;
const _commentDeletePath = '/papi/comments/delete/$_commentDeleteId';

/// One current-user entry, shaped like the live 2026-11-09 response for
/// 白鹿原 (book 11959979): the list `id` plus `readlistBookId`, null when
/// the book is not in that list.
Map<String, dynamic> _currentUserEntry({
  required Object? id,
  required Object? readlistBookId,
  String title = '',
}) {
  return {
    'id': id,
    'user_id': 35899435,
    'title': title,
    'description': '',
    'languages': null,
    'public': true,
    'adult': false,
    'editors_choice': false,
    'views_count': 0,
    'books_count': 0,
    'favorites_count': 0,
    'comments_count': 0,
    'color': 0,
    'date_updated': '2026-11-09T11:49:26.000000Z',
    'date': '2026-11-09T09:35:36.000000Z',
    'readlistBookId': readlistBookId,
  };
}
const _deleteListId = 4095945;
const _deletePath = '/papi/booklist/$_deleteListId/delete';

/// Serves canned add/delete responses so the calls run without a
/// network. Records every request's method, path, headers and body.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({
    this.addPayload = const {
      'success': 1,
      'book': {
        'readlist_id': _booklistId,
        'book_id': '$_bookId',
        'date': '2026-11-09T08:04:24.000000Z',
      },
    },
    this.deletePayload = const {'success': 1},
    this.removePayload = const {'success': 1},
    this.currentUserPayload = const {
      'success': 1,
      'list': [
        {'id': 4096101, 'readlistBookId': null},
        {'id': 4090055, 'readlistBookId': null},
        {'id': 4088695, 'readlistBookId': 161213534},
      ],
    },
  });

  Map<String, dynamic> addPayload;
  Map<String, dynamic> deletePayload;
  Map<String, dynamic> removePayload;
  Map<String, dynamic> currentUserPayload;
  int addStatusCode = 200;
  int deleteStatusCode = 200;
  int removeStatusCode = 200;
  int currentUserStatusCode = 200;
  bool deleteRedirectFirst = false;
  bool deleteRedirectAlways = false;
  bool deleteEmptyBody = false;
  // When set, the first delete redirect hop also carries
  // `set-cookie: __diamwall=<value>` (the DDoS-Guard challenge).
  String? deleteWallCookie;
  // When true, the delete redirect targets another host instead of the
  // same URL (cross-host hop: no cookie learning, Cookie header dropped).
  bool deleteRedirectCrossHost = false;
  bool removeRedirectFirst = false;
  bool removeRedirectAlways = false;
  bool removeEmptyBody = false;
  bool addEmptyBody = false;
  // Comment-like redirect hop (POST /papi/comments/like/... walks
  // `_postText`): same 307 + optional set-cookie as delete.
  bool likeRedirectFirst = false;
  String? likeWallCookie;
  // Comment-delete redirect hop (DELETE /papi/comments/delete/... walks
  // `_delete`): same 307 + optional set-cookie, same cross-host variant.
  bool commentDeleteRedirectFirst = false;
  String? commentDeleteWallCookie;
  bool commentDeleteRedirectCrossHost = false;
  Map<String, dynamic> likePayload = const {
    'success': 1,
    'likes': [
      {'item_id': _likeCommentId, 'count': 3},
    ],
    'isLiked': [
      {'item_id': _likeCommentId, 'status': 1},
    ],
  };
  Map<String, dynamic> profilePayload = const {
    'success': 1,
    'user': {
      'id': _sessionUserId,
      'email': 'reader@example.com',
      'name': 'Reader',
      'remixUserkey': _sessionUserKey,
    },
  };

  final List<String> requestedMethods = [];
  final List<String> requestedPaths = [];
  final List<Object?> requestedBodies = [];
  final List<Map<String, dynamic>> requestedHeaders = [];
  int addCalls = 0;
  int deleteCalls = 0;
  int removeCalls = 0;
  int currentUserCalls = 0;
  int likeCalls = 0;
  int commentDeleteCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    requestedMethods.add(options.method);
    requestedPaths.add(path);
    requestedBodies.add(options.data);
    requestedHeaders.add(Map<String, dynamic>.from(options.headers));
    if (path == _profilePath) {
      return _json(profilePayload);
    }
    if (path == _currentUserPath) {
      currentUserCalls++;
      return _json(currentUserPayload, statusCode: currentUserStatusCode);
    }
    if (path == _addPath) {
      addCalls++;
      if (addEmptyBody) {
        return ResponseBody.fromString(
          '',
          addStatusCode,
          headers: {Headers.contentTypeHeader: ['application/json']},
        );
      }
      return _json(addPayload, statusCode: addStatusCode);
    }
    if (path == _removePath) {
      removeCalls++;
      if (removeRedirectAlways || (removeRedirectFirst && removeCalls == 1)) {
        return ResponseBody.fromString(
          '',
          307,
          headers: {
            HttpHeaders.locationHeader: [
              // Same URL, like the real server: the API's test domain is
              // bookroom.lifestyle, so a hardcoded zh.z-library.sk here
              // would be a cross-host hop and the helper would (correctly)
              // strip the Cookie instead of following with it.
              options.uri.toString(),
            ],
          },
        );
      }
      if (removeEmptyBody) {
        return ResponseBody.fromString(
          '',
          removeStatusCode,
          headers: {Headers.contentTypeHeader: ['application/json']},
        );
      }
      return _json(removePayload, statusCode: removeStatusCode);
    }
    if (path == _likePath) {
      likeCalls++;
      if (likeRedirectFirst && likeCalls == 1) {
        final wallCookie = likeWallCookie;
        return ResponseBody.fromString(
          '',
          307,
          headers: {
            HttpHeaders.locationHeader: [
              // Same URL, like the real server (see the remove branch).
              options.uri.toString(),
            ],
            if (wallCookie != null)
              HttpHeaders.setCookieHeader: ['__diamwall=$wallCookie'],
          },
        );
      }
      return _json(likePayload);
    }
    if (path == _commentDeletePath) {
      commentDeleteCalls++;
      if (commentDeleteRedirectFirst && commentDeleteCalls == 1) {
        final wallCookie = commentDeleteWallCookie;
        return ResponseBody.fromString(
          '',
          307,
          headers: {
            HttpHeaders.locationHeader: [
              commentDeleteRedirectCrossHost
                  ? 'https://static.example.org$_commentDeletePath'
                  // Same URL, like the real server (see the remove branch).
                  : options.uri.toString(),
            ],
            if (wallCookie != null)
              HttpHeaders.setCookieHeader: ['__diamwall=$wallCookie'],
          },
        );
      }
      return _json(const {'success': 1});
    }
    if (path == _deletePath) {
      deleteCalls++;
      if (deleteRedirectAlways || (deleteRedirectFirst && deleteCalls == 1)) {
        final wallCookie = deleteWallCookie;
        return ResponseBody.fromString(
          '',
          307,
          headers: {
            HttpHeaders.locationHeader: [
              deleteRedirectCrossHost
                  ? 'https://static.example.org$_deletePath'
                  // Same URL, like the real server (see the remove branch).
                  : options.uri.toString(),
            ],
            if (wallCookie != null)
              HttpHeaders.setCookieHeader: ['__diamwall=$wallCookie'],
          },
        );
      }
      if (deleteEmptyBody) {
        return ResponseBody.fromString(
          '',
          deleteStatusCode,
          headers: {Headers.contentTypeHeader: ['application/json']},
        );
      }
      return _json(deletePayload, statusCode: deleteStatusCode);
    }
    return _json({'success': 0, 'error': 'not found'}, statusCode: 404);
  }

  ResponseBody _json(Map<String, dynamic> payload, {int statusCode = 200}) {
    return ResponseBody.fromString(
      jsonEncode(payload),
      statusCode,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

ZLibraryApi _apiWith(_FakeAdapter adapter) {
  // Plan item 5: the destructive client is a separate Dio — the fake
  // adapter has to be injected there too, or delete/remove would hit
  // the real network instead of the fake.
  return ZLibraryApi(
    dio: Dio()..httpClientAdapter = adapter,
    destructiveDio: Dio()..httpClientAdapter = adapter,
  );
}

/// Indexes (into the recorded requests) of every call to [path], in
/// order — the redirect-cookie tests pick hops out of the recording,
/// which also holds the profile request that loginWithToken makes.
List<int> _hopIndexes(List<String> paths, String path) => [
      for (var i = 0; i < paths.length; i++)
        if (paths[i] == path) i,
    ];

void main() {
  test('add sends a body-less GET to the add-book URL', () async {
    final adapter = _FakeAdapter();
    final api = _apiWith(adapter);

    final response = await api.addBookToBooklist(
      booklistId: _booklistId,
      bookId: _bookId,
    );

    expect(response.success, isTrue);
    expect(response.data, isTrue);
    expect(adapter.addCalls, 1);
    expect(adapter.requestedMethods, ['GET']);
    expect(adapter.requestedPaths, [_addPath]);
    expect(adapter.requestedBodies, [isNull]);
  });

  test('add success:0 with an error fails with that error', () async {
    final adapter = _FakeAdapter(
      addPayload: {'success': 0, 'error': 'booklist not found'},
    );
    final api = _apiWith(adapter);

    final response = await api.addBookToBooklist(
      booklistId: _booklistId,
      bookId: _bookId,
    );

    expect(response.success, isFalse);
    expect(response.error, 'booklist not found');
  });

  test('add empty body fails instead of counting as added', () async {
    final adapter = _FakeAdapter()..addEmptyBody = true;
    final api = _apiWith(adapter);

    final response = await api.addBookToBooklist(
      booklistId: _booklistId,
      bookId: _bookId,
    );

    expect(response.success, isFalse);
  });

  test('add 404 JSON error fails with the server message', () async {
    final adapter = _FakeAdapter(
      addPayload: {'success': 0, 'error': 'not found'},
    )..addStatusCode = 404;
    final api = _apiWith(adapter);

    final response = await api.addBookToBooklist(
      booklistId: _booklistId,
      bookId: _bookId,
    );

    expect(response.success, isFalse);
    expect(response.error, 'not found');
  });

  test('delete does not follow a bare 307', () async {
    // Plan item 5: only the DiamWall challenge hop (307 +
    // `__diamwall`) is followed; this 307 carries no wall markers,
    // so the delete is issued exactly once and fails instead.
    final adapter = _FakeAdapter()..deleteRedirectFirst = true;
    final api = _apiWith(adapter);

    final response = await api.deleteBooklist(_deleteListId);

    expect(response.success, isFalse);
    expect(response.error, 'redirect not followed');
    expect(adapter.deleteCalls, 1);
    expect(adapter.requestedMethods, ['GET']);
    expect(adapter.requestedPaths, [_deletePath]);
  });

  test('delete final 2xx with an empty body counts as deleted', () async {
    final adapter = _FakeAdapter()..deleteEmptyBody = true;
    final api = _apiWith(adapter);

    final response = await api.deleteBooklist(_deleteListId);

    expect(response.success, isTrue);
    expect(adapter.deleteCalls, 1);
  });

  test('delete success:0 fails with the server error', () async {
    final adapter = _FakeAdapter(
      deletePayload: {'success': 0, 'error': 'booklist not found'},
    );
    final api = _apiWith(adapter);

    final response = await api.deleteBooklist(_deleteListId);

    expect(response.success, isFalse);
    expect(response.error, 'booklist not found');
  });

  test('delete DiamWall redirect that keeps redirecting stops after the '
      'hop cap', () async {
    // The challenge hop is followed at most 3 times; the 4th 307
    // fails instead of looping forever.
    final adapter = _FakeAdapter()
      ..deleteRedirectAlways = true
      ..deleteWallCookie = 'ddg-token=';
    final api = _apiWith(adapter);

    final response = await api.deleteBooklist(_deleteListId);

    expect(response.success, isFalse);
    expect(response.error, 'redirect not followed');
    expect(adapter.deleteCalls, 4);
  });

  test('delete 307 hop set-cookie rides the follow-up request', () async {
    final adapter = _FakeAdapter()
      ..deleteRedirectFirst = true
      ..deleteWallCookie = 'ddg-token=';
    final api = _apiWith(adapter);
    final login = await api.loginWithToken(_sessionUserId, _sessionUserKey);
    expect(login.success, isTrue);

    final response = await api.deleteBooklist(_deleteListId);

    expect(response.success, isTrue);
    expect(adapter.deleteCalls, 2);
    final hops = _hopIndexes(adapter.requestedPaths, _deletePath);
    expect(hops.length, 2);
    // First hop: session only — nothing was learned yet.
    final firstHop = adapter.requestedHeaders[hops[0]];
    expect(firstHop['Cookie'], contains('remix_userid=$_sessionUserId'));
    expect(firstHop['Cookie'], contains('remix_userkey=$_sessionUserKey'));
    expect(firstHop['Cookie'], isNot(contains('__diamwall')));
    // Follow-up: the hop's __diamwall rides along next to the unchanged
    // session pair. The value keeps its trailing '=' (name/value split
    // on the first '=' only).
    final secondHop = adapter.requestedHeaders[hops[1]];
    expect(secondHop['Cookie'], contains('__diamwall=ddg-token='));
    expect(secondHop['Cookie'], contains('remix_userid=$_sessionUserId'));
    expect(secondHop['Cookie'], contains('remix_userkey=$_sessionUserKey'));
  });

  test('delete cross-host redirect is not followed', () async {
    // Plan item 5: a hop to another host is never followed, even when
    // it carries DiamWall markers — and its set-cookie is not
    // harvested, so the next same-host request carries the session
    // pair only, without the hop's cookie.
    final adapter = _FakeAdapter()
      ..deleteRedirectFirst = true
      ..deleteRedirectCrossHost = true
      ..deleteWallCookie = 'ddg-token=';
    final api = _apiWith(adapter);
    final login = await api.loginWithToken(_sessionUserId, _sessionUserKey);
    expect(login.success, isTrue);

    final response = await api.deleteBooklist(_deleteListId);

    expect(response.success, isFalse);
    expect(response.error, 'redirect not followed');
    expect(adapter.deleteCalls, 1);
    final hops = _hopIndexes(adapter.requestedPaths, _deletePath);
    expect(hops.length, 1);
    expect(adapter.requestedHeaders[hops[0]].containsKey('Cookie'), isTrue);
    await api.addBookToBooklist(booklistId: _booklistId, bookId: _bookId);
    final addHeaders = adapter.requestedHeaders.last;
    expect(addHeaders['Cookie'], contains('remix_userid=$_sessionUserId'));
    expect(addHeaders['Cookie'], isNot(contains('__diamwall')));
  });

  test('comment like 307 hop set-cookie rides the re-POSTed request',
      () async {
    final adapter = _FakeAdapter()
      ..likeRedirectFirst = true
      ..likeWallCookie = 'ddg-token=';
    final api = _apiWith(adapter);
    final login = await api.loginWithToken(_sessionUserId, _sessionUserKey);
    expect(login.success, isTrue);

    final response = await api.likeBookComment(_likeCommentId, like: true);

    expect(response.success, isTrue);
    expect(response.data?.count, 3);
    expect(response.data?.liked, isTrue);
    final hops = _hopIndexes(adapter.requestedPaths, _likePath);
    expect(hops.length, 2);
    // 307 keeps the method: the follow-up is a POST to the same URL,
    // and it carries the hop cookie next to the session pair.
    expect(adapter.requestedMethods[hops[1]], 'POST');
    final secondHop = adapter.requestedHeaders[hops[1]];
    expect(secondHop['Cookie'], contains('__diamwall=ddg-token='));
    expect(secondHop['Cookie'], contains('remix_userkey=$_sessionUserKey'));
  });

  test('comment delete 307 hop set-cookie rides the re-sent DELETE',
      () async {
    final adapter = _FakeAdapter()
      ..commentDeleteRedirectFirst = true
      ..commentDeleteWallCookie = 'ddg-token=';
    final api = _apiWith(adapter);
    final login = await api.loginWithToken(_sessionUserId, _sessionUserKey);
    expect(login.success, isTrue);

    final response = await api.deleteBookComment(_commentDeleteId);

    expect(response.success, isTrue);
    expect(response.data, isTrue);
    final hops = _hopIndexes(adapter.requestedPaths, _commentDeletePath);
    expect(hops.length, 2);
    // First hop: session only — nothing was learned yet.
    final firstHop = adapter.requestedHeaders[hops[0]];
    expect(firstHop['Cookie'], contains('remix_userid=$_sessionUserId'));
    expect(firstHop['Cookie'], isNot(contains('__diamwall')));
    // 307 keeps the method: the follow-up is a DELETE to the same URL,
    // and it carries the hop cookie next to the session pair.
    expect(adapter.requestedMethods[hops[1]], 'DELETE');
    final secondHop = adapter.requestedHeaders[hops[1]];
    expect(secondHop['Cookie'], contains('__diamwall=ddg-token='));
    expect(secondHop['Cookie'], contains('remix_userid=$_sessionUserId'));
    expect(secondHop['Cookie'], contains('remix_userkey=$_sessionUserKey'));
  });

  test('comment delete cross-host redirect learns nothing, drops the '
      'Cookie', () async {
    final adapter = _FakeAdapter()
      ..commentDeleteRedirectFirst = true
      ..commentDeleteRedirectCrossHost = true
      ..commentDeleteWallCookie = 'ddg-token=';
    final api = _apiWith(adapter);
    final login = await api.loginWithToken(_sessionUserId, _sessionUserKey);
    expect(login.success, isTrue);

    final response = await api.deleteBookComment(_commentDeleteId);

    expect(response.success, isTrue);
    final hops = _hopIndexes(adapter.requestedPaths, _commentDeletePath);
    expect(hops.length, 2);
    // The first hop went out with the session; the redirect target is
    // on another host, so its set-cookie is not harvested and the
    // follow-up request to that host carries no Cookie header at all.
    expect(adapter.requestedHeaders[hops[0]].containsKey('Cookie'), isTrue);
    expect(adapter.requestedHeaders[hops[1]].containsKey('Cookie'), isFalse);
    // Nothing entered the jar: the next same-host request carries the
    // session pair only, without the hop's cookie.
    await api.addBookToBooklist(booklistId: _booklistId, bookId: _bookId);
    final addHeaders = adapter.requestedHeaders.last;
    expect(addHeaders['Cookie'], contains('remix_userid=$_sessionUserId'));
    expect(addHeaders['Cookie'], isNot(contains('__diamwall')));
  });

  test('remove sends a body-less GET to the remove-book URL', () async {
    final adapter = _FakeAdapter();
    final api = _apiWith(adapter);

    final response = await api.removeBookFromBooklist(
      booklistId: _removeListId,
      readlistBookId: _removeEntryId,
    );

    expect(response.success, isTrue);
    expect(response.data, isTrue);
    expect(adapter.removeCalls, 1);
    expect(adapter.requestedMethods, ['GET']);
    expect(adapter.requestedPaths, [_removePath]);
    expect(adapter.requestedBodies, [isNull]);
  });

  test('remove success:0 fails with the server error', () async {
    final adapter = _FakeAdapter(
      removePayload: {'success': 0, 'error': 'book not in list'},
    );
    final api = _apiWith(adapter);

    final response = await api.removeBookFromBooklist(
      booklistId: _removeListId,
      readlistBookId: _removeEntryId,
    );

    expect(response.success, isFalse);
    expect(response.error, 'book not in list');
  });

  test('remove final 2xx with an empty body counts as removed', () async {
    final adapter = _FakeAdapter()..removeEmptyBody = true;
    final api = _apiWith(adapter);

    final response = await api.removeBookFromBooklist(
      booklistId: _removeListId,
      readlistBookId: _removeEntryId,
    );

    expect(response.success, isTrue);
    expect(adapter.removeCalls, 1);
  });

  test('remove does not follow a bare 307', () async {
    // Plan item 5: same rule as delete — a 307 without DiamWall
    // markers is not followed, so the remove is issued exactly once
    // and fails instead.
    final adapter = _FakeAdapter()..removeRedirectFirst = true;
    final api = _apiWith(adapter);

    final response = await api.removeBookFromBooklist(
      booklistId: _removeListId,
      readlistBookId: _removeEntryId,
    );

    expect(response.success, isFalse);
    expect(response.error, 'redirect not followed');
    expect(adapter.removeCalls, 1);
    expect(adapter.requestedMethods, ['GET']);
    expect(adapter.requestedPaths, [_removePath]);
  });

  test('current-user returns the entry id for the target list', () async {
    final adapter = _FakeAdapter(
      currentUserPayload: {
        'success': 1,
        'list': [
          _currentUserEntry(id: 4096101, readlistBookId: null, title: '嘎嘎嘎'),
          _currentUserEntry(id: 4090055, readlistBookId: null, title: '555'),
          _currentUserEntry(
            id: _currentUserListId,
            readlistBookId: _currentUserEntryId,
            title: '001',
          ),
        ],
      },
    );
    final api = _apiWith(adapter);

    final response = await api.getReadlistBookId(
      booklistId: _currentUserListId,
      bookId: _currentUserBookId,
    );

    expect(response.success, isTrue);
    expect(response.data, _currentUserEntryId);
    expect(adapter.currentUserCalls, 1);
    expect(adapter.requestedMethods, ['GET']);
    expect(adapter.requestedPaths, [_currentUserPath]);
    expect(adapter.requestedBodies, [isNull]);
  });

  test('current-user returns null when the book is not in the list',
      () async {
    final adapter = _FakeAdapter();
    final api = _apiWith(adapter);

    final response = await api.getReadlistBookId(
      booklistId: 4090055,
      bookId: _currentUserBookId,
    );

    expect(response.success, isTrue);
    expect(response.data, isNull);
  });

  test('current-user returns null when the target list is absent',
      () async {
    final adapter = _FakeAdapter(
      currentUserPayload: {
        'success': 1,
        'list': [
          _currentUserEntry(id: 4096101, readlistBookId: null),
        ],
      },
    );
    final api = _apiWith(adapter);

    final response = await api.getReadlistBookId(
      booklistId: _currentUserListId,
      bookId: _currentUserBookId,
    );

    expect(response.success, isTrue);
    expect(response.data, isNull);
  });

  test('current-user accepts the entry id as a numeric string', () async {
    final adapter = _FakeAdapter(
      currentUserPayload: {
        'success': 1,
        'list': [
          _currentUserEntry(
            id: '$_currentUserListId',
            readlistBookId: '$_currentUserEntryId',
          ),
        ],
      },
    );
    final api = _apiWith(adapter);

    final response = await api.getReadlistBookId(
      booklistId: _currentUserListId,
      bookId: _currentUserBookId,
    );

    expect(response.success, isTrue);
    expect(response.data, _currentUserEntryId);
  });

  test('current-user non-success JSON fails with the server error', () async {
    final adapter = _FakeAdapter(
      currentUserPayload: {'success': 0, 'error': 'not found'},
    );
    final api = _apiWith(adapter);

    final response = await api.getReadlistBookId(
      booklistId: _currentUserListId,
      bookId: _currentUserBookId,
    );

    expect(response.success, isFalse);
    expect(response.error, 'not found');
  });
}
