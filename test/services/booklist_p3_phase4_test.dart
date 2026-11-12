import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/booklist_detail_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/booklist_html_cache.dart';

// P3 + Phase-4 tests for the GPT booklist review, verified against
// main @ 4e0926b1:
// - P3-1: the detail controller's _books / _bookIds / _firstPageIds
//   stay in sync through load, merge, remove and refresh (mutations
//   go through helpers; debugInvariantsHold() proves it).
// - P3-2: getBooksPage keeps the good entries when one entry is bad,
//   and only a wholly-bad page reads as absent (and is deleted).
// - Phase-4 account-switch: the booklist cache is account-partitioned
//   (private pages carry #account=<id>); switching accounts does not
//   leak lists or books between accounts, and the public discover
//   page is shared.
// - Phase-4 API abnormal responses: createBooklist and
//   getReadlistBookId branches NOT covered by
//   booklist_add_delete_test.dart (create was never tested there;
//   current-user's malformed/no-list cases were, but its non-JSON
//   and non-list `list` cases were not).

const _user = User(
  id: '35899435',
  email: 'mingdao@example.com',
  name: 'mingdao',
  remixUserkey: 'key',
);

class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(this._state);
  final AuthState _state;
  @override
  AuthState build() => _state;
}

/// Minimal fake API for the detail controller: page-1 detail books,
/// per-page JSON books, and remove outcomes. Only the methods the
/// detail controller calls are implemented; anything else throws.
class _FakeDetailApi implements ZLibraryApi {
  List<Book> detailPage1 = const [
    Book(id: 1, title: 'One'),
    Book(id: 2, title: 'Two'),
  ];
  Map<int, List<Book>> jsonPages = const {
    2: [Book(id: 3, title: 'Three'), Book(id: 4, title: 'Four')],
    3: [Book(id: 5, title: 'Five')],
  };
  int jsonTotalPages = 3;
  bool removeSucceeds = true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  Future<ApiResponse<List<Book>>> getBooklistDetailBooks(
    Booklist list,
  ) async {
    return ApiResponse.ok(detailPage1);
  }

  @override
  Future<ApiResponse<BooklistBooksPage>> getBooklistBooks(
    String id, {
    int page = 2,
  }) async {
    final books = jsonPages[page] ?? const <Book>[];
    return ApiResponse.ok(
      BooklistBooksPage(books: books, totalPages: jsonTotalPages),
    );
  }

  @override
  Future<ApiResponse<int?>> getReadlistBookId({
    required int booklistId,
    required int bookId,
  }) async {
    return ApiResponse.ok(161213534);
  }

  @override
  Future<ApiResponse<bool>> removeBookFromBooklist({
    required int booklistId,
    required int readlistBookId,
  }) async {
    if (removeSucceeds) return ApiResponse.ok(true);
    return ApiResponse.fail('remove failed');
  }
}

const _detailUrl = 'https://example.com/booklist/4088695/hash/001.html';

const _args = BooklistDetailArgs(
  booklist: Booklist(
    id: '4088695',
    name: '001',
    url: _detailUrl,
    count: 2,
  ),
  canEdit: true,
);

/// Loads the detail controller with the fake page-1 books and waits
/// for the microtask-started loadFirst to finish.
Future<ProviderContainer> _loadedDetailContainer(
  _FakeDetailApi api,
) async {
  final container = ProviderContainer(
    overrides: [
      zlibraryApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => _FakeAuthNotifier(AuthState(user: _user))),
    ],
  );
  addTearDown(container.dispose);
  final provider = booklistDetailControllerProvider(_args);
  container.listen(provider, (_, _) {});
  await container.read(provider.notifier).initialLoadDone;
  return container;
}

/// Serves canned create / current-user responses so the calls run
/// without a network. The payload is a Map for JSON, a String for a
/// non-JSON body, or null for an empty body.
class _FakeCreateAdapter implements HttpClientAdapter {
  Object? createPayload;
  int createStatusCode = 200;
  Object? currentUserPayload;
  int currentUserStatusCode = 200;
  int createCalls = 0;
  int currentUserCalls = 0;
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
    if (path == '/papi/booklist/create' && options.method == 'POST') {
      createCalls++;
      return _serve(createPayload, createStatusCode);
    }
    if (path == '/papi/booklist/current-user/11959979') {
      currentUserCalls++;
      return _serve(currentUserPayload, currentUserStatusCode);
    }
    return _json({'success': 0, 'error': 'not found'}, statusCode: 404);
  }

  ResponseBody _serve(Object? payload, int statusCode) {
    if (payload == null) {
      return ResponseBody.fromString(
        '',
        statusCode,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );
    }
    if (payload is String) {
      return ResponseBody.fromString(
        payload,
        statusCode,
        headers: {Headers.contentTypeHeader: ['text/html']},
      );
    }
    return _json(payload as Map<String, dynamic>, statusCode: statusCode);
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

ZLibraryApi _apiWith(_FakeCreateAdapter adapter) {
  return ZLibraryApi(dio: Dio()..httpClientAdapter = adapter);
}


/// Waits for an async load/retry to paint [expected] instead of asserting
/// immediately after an await: the detail controller intentionally retries a
/// fetch that lost a race with a write, and that retry can be scheduled a
/// microtask later than the awaited call.
Future<void> _waitForIds(
  ProviderContainer container,
  BooklistDetailArgs args,
  List<int> expected,
) async {
  final provider = booklistDetailControllerProvider(args);
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    final ids = container.read(provider).books.map((book) => book.id).toList();
    if (ids.length == expected.length) {
      var same = true;
      for (var i = 0; i < ids.length; i++) {
        if (ids[i] != expected[i]) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('booklist_p3_phase4');
    Hive.init(tempDir.path);
    await Hive.openBox(BooklistHtmlCache.boxName);
  });

  setUp(() async {
    await Hive.box(BooklistHtmlCache.boxName).clear();
    BooklistHtmlCache.debugResetTokenSweep();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  // P3-1: load, merge (loadMore), remove and refresh must never
  // desync _books / _bookIds / _firstPageIds.
  test('book structures stay in sync through load, merge, remove and refresh',
      () async {
    final api = _FakeDetailApi();
    final container = await _loadedDetailContainer(api);
    final provider = booklistDetailControllerProvider(_args);
    final notifier = container.read(provider.notifier);
    bool invariants() => notifier.debugInvariantsHold();
    List<int> ids() =>
        container.read(provider).books.map((book) => book.id).toList();

    expect(invariants(), isTrue);
    expect(ids(), [1, 2]);
    await notifier.loadMore();
    expect(invariants(), isTrue);
    expect(ids(), [1, 2, 3, 4]);
    await notifier.loadMore();
    expect(invariants(), isTrue);
    expect(ids(), [1, 2, 3, 4, 5]);
    // Remove a page-2 row; the first-page ids must survive it.
    final removed =
        await notifier.removeBook(const Book(id: 3, title: 'Three'));
    expect(removed.success, isTrue);
    expect(invariants(), isTrue);
    expect(ids(), [1, 2, 4, 5]);
    // Refresh reloads page 1 (the remove invalidated the caches) and
    // the structures are rebuilt from it.
    // Let the remove's cache invalidation settle; Hive deletes are
    // fire-and-forget, so loadFirst can otherwise race the tombstone.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await notifier.loadFirst();
    await _waitForIds(container, _args, [1, 2]);
    expect(invariants(), isTrue);
    expect(ids(), [1, 2]);
    // A merge after refresh (re-fetch page 2) keeps them in sync.
    await notifier.loadMore();
    expect(invariants(), isTrue);
    expect(ids(), [1, 2, 3, 4]);
  });

  // P3-2: one bad entry must not lose the good books on the page.
  test('getBooksPage keeps good entries when one entry is bad', () {
    final box = Hive.box(BooklistHtmlCache.boxName);
    const url = 'https://example.com/booklist/1/h/x.html';
    box.put('$url#json-page=2', {
      'at': DateTime.now().millisecondsSinceEpoch,
      'books': [
        {'id': 1, 'title': 'Good One'},
        'not-a-map',
        {'id': 2, 'title': 'Good Two'},
      ],
    });
    final books = BooklistHtmlCache.getBooksPage(url, 2);
    expect(books?.map((book) => book.id).toList(), [1, 2]);
    // The page itself is kept (only the bad entry is skipped).
    expect(box.containsKey('$url#json-page=2'), isTrue);
  });

  // P3-2: a page whose every entry is bad is corrupt: null + deleted.
  test('getBooksPage returns null and deletes a wholly corrupt page', () {
    final box = Hive.box(BooklistHtmlCache.boxName);
    const url = 'https://example.com/booklist/1/h/x.html';
    box.put('$url#json-page=2', {
      'at': DateTime.now().millisecondsSinceEpoch,
      'books': ['not-a-map', 42],
    });
    expect(BooklistHtmlCache.getBooksPage(url, 2), isNull);
    expect(box.containsKey('$url#json-page=2'), isFalse);
  });

  // P3-2: a stored empty page is valid, not corrupt.
  test('getBooksPage returns an empty list for a valid empty page', () {
    const url = 'https://example.com/booklist/1/h/x.html';
    Hive.box(BooklistHtmlCache.boxName).put('$url#json-page=2', {
      'at': DateTime.now().millisecondsSinceEpoch,
      'books': <dynamic>[],
    });
    final books = BooklistHtmlCache.getBooksPage(url, 2);
    expect(books, isNotNull);
    expect(books, isEmpty);
  });

  // Phase-4 account-switch: a mine page cached under account A must
  // not be visible under account B, signed out, or the public key.
  test('mine page cached under account A is invisible to B and signed-out',
      () {
    const url = 'https://example.com/booklists/my?page=1';
    BooklistHtmlCache.store(url, '<html>mine A</html>', accountId: 'A');
    expect(
      BooklistHtmlCache.get(url, accountId: 'A'),
      '<html>mine A</html>',
    );
    expect(BooklistHtmlCache.get(url, accountId: 'B'), isNull);
    expect(BooklistHtmlCache.get(url, accountId: 'signed-out'), isNull);
    expect(BooklistHtmlCache.get(url), isNull);
  });

  // Phase-4 account-switch: parsed detail pages are partitioned too.
  test('detail books page cached under account A is invisible to B', () {
    const url = 'https://example.com/booklist/4088695/h/001.html';
    BooklistHtmlCache.storeBooksPage(
      url,
      2,
      [const Book(id: 3, title: 'Three'), const Book(id: 4, title: 'Four')],
      accountId: 'A',
    );
    expect(
      BooklistHtmlCache.getBooksPage(url, 2, accountId: 'A')
          ?.map((book) => book.id)
          .toList(),
      [3, 4],
    );
    expect(BooklistHtmlCache.getBooksPage(url, 2, accountId: 'B'), isNull);
    expect(
      BooklistHtmlCache.getBooksPage(url, 2, accountId: 'signed-out'),
      isNull,
    );
  });

  // Phase-4 account-switch: the public discover page is shared — it
  // is stored and read without an account partition.
  test('discover page is shared without an account partition', () {
    const url = 'https://example.com/booklists?page=1';
    BooklistHtmlCache.store(url, '<html>discover</html>');
    expect(BooklistHtmlCache.get(url), '<html>discover</html>');
    // The public entry is not filed under any account key.
    expect(BooklistHtmlCache.get(url, accountId: 'A'), isNull);
  });

  // Phase-4 account-switch: invalidating one account's booklist must
  // not clear another account's entry for the same URL.
  test('invalidateBooklist only clears the given account partition', () {
    const url = 'https://example.com/booklist/4088695/h/001.html';
    BooklistHtmlCache.storeBooksPage(
      url,
      2,
      [const Book(id: 3, title: 'Three')],
      accountId: 'A',
    );
    BooklistHtmlCache.storeBooksPage(
      url,
      2,
      [const Book(id: 3, title: 'Three')],
      accountId: 'B',
    );
    BooklistHtmlCache.invalidateBooklist(url, accountId: 'A');
    expect(BooklistHtmlCache.getBooksPage(url, 2, accountId: 'A'), isNull);
    expect(
      BooklistHtmlCache.getBooksPage(url, 2, accountId: 'B')
          ?.map((book) => book.id)
          .toList(),
      [3],
    );
  });

  // Phase-4 API: createBooklist was never covered by the add/delete
  // tests. An empty title fails before any request is made.
  test('create with an empty title fails without a request', () async {
    final adapter = _FakeCreateAdapter();
    final api = _apiWith(adapter);
    final response = await api.createBooklist(title: '   ');
    expect(response.success, isFalse);
    expect(response.error, 'booklist title is empty');
    expect(adapter.createCalls, 0);
  });

  // Phase-4 API: the confirmed 2026-11-07 capture — create answers
  // with an empty body on success.
  test('create with an empty-body 2xx succeeds', () async {
    final adapter = _FakeCreateAdapter()..createPayload = null;
    final api = _apiWith(adapter);
    final response = await api.createBooklist(title: 'New List');
    expect(response.success, isTrue);
    expect(response.data, isNull);
    expect(adapter.createCalls, 1);
    expect(adapter.requestedMethods, ['POST']);
    expect(adapter.requestedPaths, ['/papi/booklist/create']);
  });

  // Phase-4 API: a JSON failure flag fails with the server message.
  test('create with a JSON error fails with the server message', () async {
    final adapter = _FakeCreateAdapter()
      ..createPayload = {'success': 0, 'error': 'Too many lists'};
    final api = _apiWith(adapter);
    final response = await api.createBooklist(title: 'New List');
    expect(response.success, isFalse);
    expect(response.error, 'Too many lists');
  });

  // Phase-4 API: a non-JSON 200 body is not a successful create.
  test('create with a non-JSON body fails', () async {
    final adapter = _FakeCreateAdapter()
      ..createPayload = '<html>not json</html>';
    final api = _apiWith(adapter);
    final response = await api.createBooklist(title: 'New List');
    expect(response.success, isFalse);
  });

  // Phase-4 API: a JSON success carrying a booklist returns it.
  test('create with a JSON success carrying a booklist returns it', () async {
    final adapter = _FakeCreateAdapter()
      ..createPayload = {
        'success': 1,
        'booklist': {'id': '4096101', 'title': 'New List'},
      };
    final api = _apiWith(adapter);
    final response = await api.createBooklist(title: 'New List');
    expect(response.success, isTrue);
    expect(response.data?.id, '4096101');
    expect(response.data?.name, 'New List');
  });

  // Phase-4 API: current-user with a non-JSON body fails (the
  // existing tests cover null/absent/non-success, not this).
  test('current-user with a non-JSON body fails', () async {
    final adapter = _FakeCreateAdapter()
      ..currentUserPayload = '<html>not json</html>';
    final api = _apiWith(adapter);
    final response = await api.getReadlistBookId(
      booklistId: 4088695,
      bookId: 11959979,
    );
    expect(response.success, isFalse);
    expect(adapter.currentUserCalls, 1);
  });

  // Phase-4 API: success:1 but no `list` at all is malformed.
  test('current-user with success but no list fails', () async {
    final adapter = _FakeCreateAdapter()
      ..currentUserPayload = {'success': 1};
    final api = _apiWith(adapter);
    final response = await api.getReadlistBookId(
      booklistId: 4088695,
      bookId: 11959979,
    );
    expect(response.success, isFalse);
    expect(response.error, 'get booklist entry failed');
  });

  // Phase-4 API: success:1 but `list` is not a list is malformed.
  test('current-user with a non-list list fails', () async {
    final adapter = _FakeCreateAdapter()
      ..currentUserPayload = {
        'success': 1,
        'list': {'id': 4088695, 'readlistBookId': 1},
      };
    final api = _apiWith(adapter);
    final response = await api.getReadlistBookId(
      booklistId: 4088695,
      bookId: 11959979,
    );
    expect(response.success, isFalse);
    expect(response.error, 'get booklist entry failed');
  });
}