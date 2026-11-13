// P2-5 regression tests (zlibx-3 review): booklist detail pagination
// and cache state invariants for BooklistDetailController.
//
// The controller's generation guard, the id-keyed _books/_bookIds
// structures and the remove-time cache invalidation are what keep a
// stale response from resurrecting or duplicating rows. These tests
// pin that behaviour down for a loadMore racing a refresh, deleting
// the last book on a page, a refresh after a delete, two overlapping
// first-page loads, and an empty booklist versus an error.
//
// Follows test/services/booklist_gpt_fixes_test.dart's harness: a fake
// ZLibraryApi (implements + noSuchMethod), a fake AuthNotifier, a
// throwaway Hive directory, and a ProviderContainer that listens to
// the controller so the autoDispose notifier stays alive. The detail
// controller's `initialLoadDone` is used instead of a delay so each
// test starts from a stable state.
//
// Skipped / not testable with the existing fakes:
// - (c) the concurrent cases (remove invalidates all page caches;
//   remove retires an in-flight load; refresh during a remove retries
//   once) are already covered in test/services/booklist_gpt_fixes_test.dart.
//   What was missing — the sequential case, remove completes THEN a
//   refresh runs — is tested here.
// - (e) the solver-specific variant (solver returns null HTML vs
//   solver returns HTML that parses to an empty list) cannot be
//   tested in a unit test: _loadViaSolver calls the real static
//   BooklistSolver.fetchHtml, which opens a real WebView
//   (WebviewChallengeSolver.fetchHtmlAfterChallenge) and has no
//   injection point in the fake API. The fast-path equivalent — a
//   legitimately empty first page versus a non-challenge failure —
//   is tested here and exercises the same _applyFirstPage/_fail
//   distinction.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/booklist_detail_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/booklist_html_cache.dart';

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

Book _book(int id) => Book(id: id, title: 'Book $id');

Booklist _list(String id) => Booklist(
      id: id,
      name: 'List $id',
      url: 'https://z.example/booklist/$id',
    );

class _FakeZLibraryApi implements ZLibraryApi {
  /// Canned first page (detail HTML path). Mutable so a test can
  /// model the server after a delete.
  List<Book> detailPage1 = [_book(1), _book(2)];

  /// Ordered gates for getBooklistDetailBooks, consumed in order.
  /// When non-empty, the next detail fetch waits on the first gate.
  final detailGates = <Completer<ApiResponse<List<Book>>>>[];

  /// When true, the detail fetch fails with a plain (non-challenge)
  /// error, so the controller reports the failure instead of falling
  /// back to the WebView solver.
  bool failDetail = false;

  /// JSON pages for getBooklistBooks, keyed by page.
  final jsonPages = <int, List<Book>>{};
  int jsonTotalPages = 1;

  /// Ordered gates for getBooklistBooks, consumed in order.
  final jsonGates = <Completer<ApiResponse<BooklistBooksPage>>>[];

  int removeCalls = 0;

  @override
  Future<ApiResponse<List<Book>>> getBooklistDetailBooks(
    Booklist list,
  ) async {
    if (failDetail) return ApiResponse.fail('network error');
    if (detailGates.isNotEmpty) {
      return detailGates.removeAt(0).future;
    }
    return ApiResponse.ok(detailPage1);
  }

  @override
  Future<ApiResponse<BooklistBooksPage>> getBooklistBooks(
    String id, {
    int page = 2,
  }) async {
    if (jsonGates.isNotEmpty) {
      return jsonGates.removeAt(0).future;
    }
    return ApiResponse.ok(
      BooklistBooksPage(
        books: jsonPages[page] ?? const [],
        totalPages: jsonTotalPages,
      ),
    );
  }

  @override
  Future<ApiResponse<int?>> getReadlistBookId({
    required int booklistId,
    required int bookId,
  }) async =>
      ApiResponse.ok(161213534);

  @override
  Future<ApiResponse<bool>> removeBookFromBooklist({
    required int booklistId,
    required int readlistBookId,
  }) async {
    removeCalls++;
    return ApiResponse.ok(true);
  }

  @override
  String booklistsPageUrl({
    required bool mine,
    String query = '',
    String? order,
    int page = 1,
  }) =>
      'https://example.com/booklists/my?page=$page';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected call: ${invocation.memberName}');
}

ProviderContainer _container(_FakeZLibraryApi api) {
  final container = ProviderContainer(
    overrides: [
      zlibraryApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => _FakeAuthNotifier(AuthState(user: _user))),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

BooklistDetailArgs _args(Booklist list) => BooklistDetailArgs(booklist: list);

Future<BooklistDetailController> _loadedDetail(
  ProviderContainer container,
  Booklist list,
) async {
  final args = _args(list);
  container.listen(booklistDetailControllerProvider(args), (_, _) {});
  final notifier =
      container.read(booklistDetailControllerProvider(args).notifier);
  await notifier.initialLoadDone;
  return notifier;
}

List<int> _bookIds(ProviderContainer container, BooklistDetailArgs args) =>
    container
        .read(booklistDetailControllerProvider(args))
        .books
        .map((b) => b.id)
        .toList();

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir =
        await Directory.systemTemp.createTemp('booklist_detail_state_test');
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

  test('(a) a loadMore in flight when a refresh starts is dropped, '
      'not duplicated', () async {
    final api = _FakeZLibraryApi();
    api.jsonPages[2] = [_book(3), _book(4)];
    api.jsonTotalPages = 2;
    final container = _container(api);
    final list = _list('1');
    final args = _args(list);
    final notifier = await _loadedDetail(container, list);
    expect(_bookIds(container, args), [1, 2]);

    // Hold the page-2 loadMore on a gate.
    final page2Gate = Completer<ApiResponse<BooklistBooksPage>>();
    api.jsonGates.add(page2Gate);
    final loadMore = notifier.loadMore();
    // While the loadMore is in flight, refresh (loadFirst).
    final refresh = notifier.loadFirst();
    await refresh;
    // Release the stale page-2 response.
    page2Gate.complete(
      ApiResponse.ok(
        BooklistBooksPage(books: [_book(3), _book(4)], totalPages: 2),
      ),
    );
    await loadMore;
    // The stale page-2 rows must NOT have been merged in.
    final state = container.read(booklistDetailControllerProvider(args));
    expect(_bookIds(container, args), [1, 2]);
    expect(state.nextPage, 2);
    expect(state.hasMore, isTrue);
    expect(notifier.debugInvariantsHold(), isTrue);
  });

  test('(b) deleting the last book on the current page keeps pagination '
      'consistent', () async {
    final api = _FakeZLibraryApi();
    api.jsonPages[2] = [_book(3), _book(4)];
    api.jsonPages[3] = [_book(5)];
    api.jsonTotalPages = 3;
    final container = _container(api);
    final list = _list('1');
    final args = _args(list);
    final notifier = await _loadedDetail(container, list);
    expect(_bookIds(container, args), [1, 2]);

    // Load page 2.
    await notifier.loadMore();
    expect(_bookIds(container, args), [1, 2, 3, 4]);
    var state = container.read(booklistDetailControllerProvider(args));
    expect(state.hasMore, isTrue);
    expect(state.nextPage, 3);

    // Delete the last book on the loaded page (book 4).
    final response = await notifier.removeBook(_book(4));
    expect(response.success, isTrue);
    expect(api.removeCalls, 1);
    expect(_bookIds(container, args), [1, 2, 3]);
    state = container.read(booklistDetailControllerProvider(args));
    expect(state.hasMore, isTrue);
    expect(state.nextPage, 3);
    expect(notifier.debugInvariantsHold(), isTrue);

    // The next page still loads cleanly after the delete.
    await notifier.loadMore();
    expect(_bookIds(container, args), [1, 2, 3, 5]);
    state = container.read(booklistDetailControllerProvider(args));
    expect(state.hasMore, isFalse);
    expect(state.nextPage, 4);
    expect(notifier.debugInvariantsHold(), isTrue);
  });

  test('(c) a refresh after a successful delete does not resurrect the book',
      () async {
    final api = _FakeZLibraryApi();
    final container = _container(api);
    final list = _list('1');
    final args = _args(list);
    final notifier = await _loadedDetail(container, list);
    expect(_bookIds(container, args), [1, 2]);

    // Delete book 1. The server's page 1 no longer carries it.
    final response = await notifier.removeBook(_book(1));
    expect(response.success, isTrue);
    expect(api.removeCalls, 1);
    expect(_bookIds(container, args), [2]);
    api.detailPage1 = [_book(2)];

    // Refresh: the cache was invalidated by the delete, so the fresh
    // page 1 (without book 1) is fetched and painted.
    await notifier.loadFirst();
    expect(_bookIds(container, args), [2]);
    expect(notifier.debugInvariantsHold(), isTrue);
  });

  test('(d) an older loadFirst response is dropped when a newer loadFirst '
      'started', () async {
    final api = _FakeZLibraryApi();
    final container = _container(api);
    final list = _list('1');
    final args = _args(list);
    final notifier = await _loadedDetail(container, list);
    expect(_bookIds(container, args), [1, 2]);

    // Hold the next two page-1 fetches on gates, in call order.
    final gate1 = Completer<ApiResponse<List<Book>>>();
    final gate2 = Completer<ApiResponse<List<Book>>>();
    api.detailGates.addAll([gate1, gate2]);
    final refresh1 = notifier.loadFirst();
    final refresh2 = notifier.loadFirst();
    // The newer refresh's page is the fresh one; the older one is stale.
    gate2.complete(ApiResponse.ok([_book(9)]));
    await refresh2;
    expect(_bookIds(container, args), [9]);
    gate1.complete(ApiResponse.ok([_book(1), _book(2)]));
    await refresh1;
    // The stale page-1 response must NOT have overwritten the fresh one.
    expect(_bookIds(container, args), [9]);
    expect(notifier.debugInvariantsHold(), isTrue);
  });

  test('(e) a legitimately empty booklist is an empty state, not an error',
      () async {
    final api = _FakeZLibraryApi()..detailPage1 = [];
    final container = _container(api);
    final list = _list('1');
    final args = _args(list);
    final notifier = await _loadedDetail(container, list);
    final state = container.read(booklistDetailControllerProvider(args));
    expect(state.books, isEmpty);
    expect(state.error, isNull);
    expect(state.isLoading, isFalse);
    expect(state.hasMore, isFalse);
    expect(notifier.debugInvariantsHold(), isTrue);
  });

  test('(e) a non-challenge first-page failure is an error state', () async {
    final api = _FakeZLibraryApi()..failDetail = true;
    final container = _container(api);
    final list = _list('1');
    final args = _args(list);
    final notifier = await _loadedDetail(container, list);
    final state = container.read(booklistDetailControllerProvider(args));
    expect(state.books, isEmpty);
    expect(state.error, 'network error');
    expect(state.isLoading, isFalse);
    expect(notifier.debugInvariantsHold(), isTrue);
  });
}
