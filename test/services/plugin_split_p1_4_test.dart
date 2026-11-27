import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

// Split-wiring tests for the review-2 P1-4 split of
// `zlibrary_api.dart` and `zlibrary_booklists.dart`: every new file is
// exercised through the public [ZLibraryApi] surface with a fake
// adapter (no network), so a missing `part` directive, a dropped
// mixin in the `with` clause, or a broken extension call fails here
// instead of silently shipping.
//
// - `zlibrary_booklists.dart` (reads): list-page URL building and the
//   page-2 JSON endpoint.
// - `zlibrary_booklist_writes.dart`: create validation and the colour
//   endpoint.
// - `zlibrary_booklist_membership.dart`: entry-id lookup, add, and
//   the destructive-client remove.
// - `zlibrary_http.dart` + `zlibrary_responses.dart`: the form POST
//   and the response funnel, via `search` (success and JSON-error).
// - `zlibrary_download_types.dart` and `zlibrary_destructive.dart`
//   are covered by the same calls: the remove goes through the
//   destructive client, and the download exception types are already
//   pinned by `plugin_network_test.dart`.
//
// All ids, titles and hashes below are SYNTHETIC — no real user data.

const _listId = 1001;
const _bookId = 2002;
const _entryId = 3003;
const _searchPath = '/eapi/book/search';
const _booksPath = '/papi/booklist/$_listId/get-books/2';
const _colorPath = '/papi/booklist/$_listId/color/4';
const _currentUserPath = '/papi/booklist/current-user/$_bookId';
const _addPath = '/papi/booklist/$_listId/add-book/$_bookId';
const _removePath = '/papi/booklist/$_listId/remove-book/$_entryId';

/// Serves canned responses so the calls run without a network.
/// Records every request's method and path, from both Dio clients.
class _FakeAdapter implements HttpClientAdapter {
  bool searchError = false;

  final List<String> requestedMethods = [];
  final List<String> requestedPaths = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    requestedMethods.add(options.method);
    requestedPaths.add(path);
    switch (path) {
      case _searchPath:
        if (searchError) {
          return _json(const {'success': 0, 'error': 'Access denied'});
        }
        return _json(const {
          'success': 1,
          'books': [
            {'id': 1, 'title': 'Split Test', 'hash': 'abcdef'},
          ],
          'pagination': {'current': 1, 'total_pages': 1},
        });
      case _booksPath:
        return _json(const {
          'success': 1,
          'books': [
            {
              'book': {
                'id': 2002,
                'title': 'Member Book',
                'href': '/book/abcdef/member-book.html',
              },
            },
          ],
          'pagination': {'total_pages': 3},
        });
      case _colorPath:
        return _json(const {'success': 1});
      case _currentUserPath:
        return _json(const {
          'success': 1,
          'list': [
            {'id': 1001, 'title': 'Test List Alpha', 'readlistBookId': 3003},
          ],
        });
      case _addPath:
        return _json(const {
          'success': 1,
          'book': {'readlist_id': 3003, 'book_id': '2002'},
        });
      case _removePath:
        return _json(const {'success': 1});
      default:
        return _json(
          {'success': 0, 'error': 'not found'},
          statusCode: 404,
        );
    }
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
  // The destructive client is a separate Dio — the fake adapter has
  // to be injected there too, or removeBookFromBooklist would hit
  // the real network instead of the fake.
  return ZLibraryApi(
    dio: Dio()..httpClientAdapter = adapter,
    destructiveDio: Dio()..httpClientAdapter = adapter,
  );
}

void main() {
  group('reads (zlibrary_booklists.dart)', () {
    test('booklistsPageUrl builds the public / mine / favorite URLs', () {
      final api = _apiWith(_FakeAdapter());

      expect(api.booklistsPageUrl(mine: false), contains('/booklists?'));
      expect(
        api.booklistsPageUrl(mine: true),
        contains('/booklists/my?'),
      );
      expect(
        api.booklistsPageUrl(mine: false, favorite: true),
        contains('/booklists/favorite?'),
      );
    });

    test('getBooklistBooks reads the page-2 JSON endpoint', () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);

      final response = await api.getBooklistBooks('$_listId', page: 2);

      expect(response.success, isTrue);
      expect(response.data?.books.length, 1);
      expect(response.data?.books.single.id, _bookId);
      expect(response.data?.books.single.title, 'Member Book');
      expect(response.data?.totalPages, 3);
      expect(adapter.requestedMethods, ['GET']);
      expect(adapter.requestedPaths, [_booksPath]);
    });

    test('getUserProfileBooklistsPage rejects page 1 without a request',
        () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);

      final response = await api.getUserProfileBooklistsPage(
        userId: '1790607',
        userHash: 'f094e9',
        page: 1,
      );

      expect(response.success, isFalse);
      expect(adapter.requestedPaths, isEmpty);
    });
  });

  group('writes (zlibrary_booklist_writes.dart)', () {
    test('createBooklist rejects an empty title without a request',
        () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);

      final response = await api.createBooklist(title: '  ');

      expect(response.success, isFalse);
      expect(adapter.requestedPaths, isEmpty);
    });

    test('setBooklistColor GETs the color URL', () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);

      final response = await api.setBooklistColor(id: _listId, color: 4);

      expect(response.success, isTrue);
      expect(response.data, isTrue);
      expect(adapter.requestedMethods, ['GET']);
      expect(adapter.requestedPaths, [_colorPath]);
    });
  });

  group('membership (zlibrary_booklist_membership.dart)', () {
    test('getReadlistBookId resolves the entry id', () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);

      final response = await api.getReadlistBookId(
        booklistId: _listId,
        bookId: _bookId,
      );

      expect(response.success, isTrue);
      expect(response.data, _entryId);
      expect(adapter.requestedPaths, [_currentUserPath]);
    });

    test('addBookToBooklist returns true', () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);

      final response = await api.addBookToBooklist(
        booklistId: _listId,
        bookId: _bookId,
      );

      expect(response.success, isTrue);
      expect(response.data, isTrue);
      expect(adapter.requestedPaths, [_addPath]);
    });

    test('removeBookFromBooklist goes through the destructive client',
        () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);

      final response = await api.removeBookFromBooklist(
        booklistId: _listId,
        readlistBookId: _entryId,
      );

      expect(response.success, isTrue);
      expect(response.data, isTrue);
      expect(adapter.requestedMethods, ['GET']);
      expect(adapter.requestedPaths, [_removePath]);
    });
  });

  group('http + responses (zlibrary_http.dart / zlibrary_responses.dart)',
      () {
    test('search posts the form and decodes one book', () async {
      final adapter = _FakeAdapter();
      final api = _apiWith(adapter);

      final response = await api.search(message: 'Split Test');

      expect(response.success, isTrue);
      expect(response.data?.length, 1);
      expect(response.data?.single.id, 1);
      expect(response.data?.single.title, 'Split Test');
      expect(response.data?.single.hash, 'abcdef');
      expect(response.meta?['total_pages'], 1);
      expect(adapter.requestedMethods, ['POST']);
      expect(adapter.requestedPaths, [_searchPath]);
    });

    test('search surfaces a JSON error body', () async {
      final adapter = _FakeAdapter()..searchError = true;
      final api = _apiWith(adapter);

      final response = await api.search(message: 'Split Test');

      expect(response.success, isFalse);
      expect(response.error, 'Access denied');
    });
  });
}
