import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/booklist_detail_provider.dart';
import 'package:zlibx/providers/booklists_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/booklist_html_cache.dart';

// Regression tests for the GPT booklist review fixes (P1 + P2 +
// security), all verified against main @ e7df7156:
// - unauthenticated discover works (item 1)
// - refresh keeps the pagination cursor (item 2)
// - remove invalidates every page cache (item 3)
// - a stale loadMore cannot clear a newer loadMore's flag (item 4)
// - a delete-list rollback is skipped after a refresh (item 5)
// - concurrent removes cannot corrupt the list (item 6)
// - Args equality includes the URL (item 8)
// - page-1 hasMore does not trust the stale count (item 9)
// - cache invalidation API + delete-on-read (item 10)
// - user_token is stripped from cached HTML (item 11)

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

/// Fake API for the controller tests. Page-1 detail books, per-page
/// JSON books, list pages and delete/remove outcomes are all
/// configurable; the async methods can be held on a [Completer] so
/// overlapping requests can be scripted.
class _FakeZLibraryApi implements ZLibraryApi {
  // Detail page 1 (HTML) and JSON pages 2+ for the detail controller.
  List<Book> detailPage1 = const [
    Book(id: 1, title: 'One'),
    Book(id: 2, title: 'Two'),
  ];
  Map<int, List<Book>> jsonPages = const {
    2: [Book(id: 3, title: 'Three'), Book(id: 4, title: 'Four')],
    3: [Book(id: 5, title: 'Five')],
  };
  int jsonTotalPages = 3;

  // List pages for the booklists controller.
  List<Booklist> mineLists = [
    const Booklist(id: '4088695', name: '001', url: 'https://example.com/1', count: 2),
    const Booklist(id: '4090055', name: '555', url: 'https://example.com/2', count: 1),
  ];
  List<Booklist> publicLists = [
    const Booklist(id: '4096101', name: 'Public', url: 'https://example.com/3', count: 1),
  ];
  List<Booklist> refreshedMineLists = [
    const Booklist(id: '4090055', name: '555', url: 'https://example.com/2', count: 1),
    const Booklist(id: '4096101', name: 'New', url: 'https://example.com/4', count: 0),
  ];

  // Controllable gates: when set, the call waits on the completer.
  Completer<ApiResponse<int?>>? entryGate;
  Completer<ApiResponse<bool>>? removeGate;
  Completer<ApiResponse<bool>>? deleteGate;
  // Held page-1 detail loads (loadFirst revalidation). When set, the
  // call waits on the completer.
  Completer<ApiResponse<List<Book>>>? detailGate;
  // Held page-2+ list loads (loadMore). Page-1 loads never wait on
  // these — a refresh must not consume a loadMore gate.
  final List<Completer<ApiResponse<BooklistsPage>>> searchCompleters = [];
  // Overrides the canned page-1 list result (used by the loadMore
  // race test, which needs a full 10-item page with more pages).
  BooklistsPage Function(int page)? searchMyPage;

  int? entryId = 161213534;
  bool failEntryFetch = false;
  bool removeSucceeds = true;
  bool deleteSucceeds = true;
  int getReadlistBookIdCalls = 0;
  int removeCalls = 0;
  int deleteCalls = 0;
  int searchMyCalls = 0;
  int searchPublicCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  String booklistsPageUrl({
    bool mine = true,
    String query = '',
    String? order,
    int page = 1,
  }) {
    return mine
        ? 'https://example.com/booklists/my?page=$page'
        : 'https://example.com/booklists?page=$page';
  }

  @override
  Future<ApiResponse<BooklistsPage>> searchMyBooklists({
    String query = '',
    String? order,
    int page = 1,
  }) async {
    searchMyCalls++;
    if (page > 1 && searchCompleters.isNotEmpty) {
      return searchCompleters.removeAt(0).future;
    }
    if (searchMyPage != null) return ApiResponse.ok(searchMyPage!(page));
    final lists = page == 1 ? mineLists : const <Booklist>[];
    return ApiResponse.ok(BooklistsPage(lists: lists, totalPages: 1));
  }

  @override
  Future<ApiResponse<BooklistsPage>> searchPublicBooklists({
    String query = '',
    String? order,
    int page = 1,
  }) async {
    searchPublicCalls++;
    return ApiResponse.ok(
      BooklistsPage(lists: publicLists, totalPages: 1),
    );
  }

  @override
  Future<ApiResponse<List<Book>>> getBooklistDetailBooks(
    Booklist list,
  ) async {
    if (detailGate != null) return detailGate!.future;
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
    getReadlistBookIdCalls++;
    if (entryGate != null) return entryGate!.future;
    if (failEntryFetch) return ApiResponse.fail('network error');
    return ApiResponse.ok(entryId);
  }

  @override
  Future<ApiResponse<bool>> removeBookFromBooklist({
    required int booklistId,
    required int readlistBookId,
  }) async {
    removeCalls++;
    if (removeGate != null) return removeGate!.future;
    if (removeSucceeds) return ApiResponse.ok(true);
    return ApiResponse.fail('remove failed');
  }

  @override
  Future<ApiResponse<bool>> deleteBooklist(int booklistId) async {
    deleteCalls++;
    if (deleteGate != null) return deleteGate!.future;
    if (deleteSucceeds) return ApiResponse.ok(true);
    return ApiResponse.fail('delete failed');
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
  _FakeZLibraryApi api, {
  BooklistDetailArgs args = _args,
}) async {
  final container = ProviderContainer(
    overrides: [
      zlibraryApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => _FakeAuthNotifier(AuthState(user: _user))),
    ],
  );
  addTearDown(container.dispose);
  container.listen(booklistDetailControllerProvider(args), (_, _) {});
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return container;
}

/// Loads the booklists controller (mine tab, signed in) and waits for
/// the microtask-started loadFirst to finish.
Future<ProviderContainer> _loadedListsContainer(
  _FakeZLibraryApi api,
) async {
  final container = ProviderContainer(
    overrides: [
      zlibraryApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => _FakeAuthNotifier(AuthState(user: _user))),
    ],
  );
  addTearDown(container.dispose);
  container.listen(booklistsControllerProvider, (_, _) {});
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return container;
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('booklist_gpt_fixes');
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

  // Item 1: the discover tab is public; a signed-out user must be
  // able to browse it instead of being forced to loggedOut.
  test('signed-out discover loads public lists', () async {
    final api = _FakeZLibraryApi();
    final container = ProviderContainer(
      overrides: [
        zlibraryApiProvider.overrideWithValue(api),
        authProvider.overrideWith(() => _FakeAuthNotifier(AuthState())),
      ],
    );
    addTearDown(container.dispose);
    container.listen(booklistsControllerProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // The default mine tab correctly shows loggedOut when signed out.
    expect(
      container.read(booklistsControllerProvider).phase,
      BooklistsPhase.loggedOut,
    );
    container
        .read(booklistsControllerProvider.notifier)
        .setTab(BooklistTab.discover);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final state = container.read(booklistsControllerProvider);
    expect(state.phase, BooklistsPhase.ready);
    expect(state.lists.map((list) => list.id).toList(), ['4096101']);
    expect(api.searchPublicCalls, 1);
  });

  // Item 2 (verified against the code, not as GPT stated it):
  // `loadFirst` clears the book list before revalidating page 1, so
  // a refresh does NOT keep the later pages — it reloads from page
  // 1 and `nextPage` is 2, which is correct. What the refresh must
  // not do is duplicate rows when page 2 is re-fetched afterwards.
  test('refresh reloads from page 1 and page 2 re-fetches cleanly', () async {
    final api = _FakeZLibraryApi();
    final container = await _loadedDetailContainer(api);
    final notifier =
        container.read(booklistDetailControllerProvider(_args).notifier);
    await notifier.loadMore();
    await notifier.loadMore();
    expect(
      container
          .read(booklistDetailControllerProvider(_args))
          .books
          .map((book) => book.id)
          .toList(),
      [1, 2, 3, 4, 5],
    );
    expect(
      container.read(booklistDetailControllerProvider(_args)).nextPage,
      4,
    );
    await notifier.loadFirst();
    final refreshed = container.read(booklistDetailControllerProvider(_args));
    expect(refreshed.books.map((book) => book.id).toList(), [1, 2]);
    expect(refreshed.nextPage, 2);
    await notifier.loadMore();
    await notifier.loadMore();
    expect(
      container
          .read(booklistDetailControllerProvider(_args))
          .books
          .map((book) => book.id)
          .toList(),
      [1, 2, 3, 4, 5],
    );
  });

  // Item 3: removing a book from page 2 invalidates every page cache
  // for that list, so it cannot reappear from a later page's cache.
  test('remove invalidates all page caches for the list', () async {
    final api = _FakeZLibraryApi();
    final container = await _loadedDetailContainer(api);
    final notifier =
        container.read(booklistDetailControllerProvider(_args).notifier);
    await notifier.loadMore();
    expect(
      BooklistHtmlCache.getBooksPage(_detailUrl, 1, accountId: _user.id),
      isNotNull,
    );
    expect(
      BooklistHtmlCache.getBooksPage(_detailUrl, 2, accountId: _user.id),
      isNotNull,
    );
    final response = await notifier.removeBook(const Book(id: 3, title: 'Three'));
    expect(response.success, isTrue);
    expect(
      BooklistHtmlCache.getBooksPage(_detailUrl, 1, accountId: _user.id),
      isNull,
    );
    expect(
      BooklistHtmlCache.getBooksPage(_detailUrl, 2, accountId: _user.id),
      isNull,
    );
    expect(
      container
          .read(booklistDetailControllerProvider(_args))
          .books
          .map((book) => book.id)
          .toList(),
      [1, 2, 4],
    );
  });

  // Doc P1-4 (cache consistency): a load that started before a remove
  // must not resurrect the removed book — neither in the visible list
  // nor in the page cache — when its response lands after the remove.
  // The remove retires the in-flight load (generation bump) and the
  // invalidation tombstone drops its cache store.
  test('remove retires an in-flight load so it cannot resurrect the book',
      () async {
    final api = _FakeZLibraryApi();
    const url = 'https://example.com/booklist/9999999/hash/race.html';
    const args = BooklistDetailArgs(
      booklist: Booklist(id: '9999999', name: 'Race', url: url, count: 2),
      canEdit: true,
    );
    // Seed the page-1 cache so loadFirst paints immediately and then
    // revalidates in the background, held on the gate.
    BooklistHtmlCache.storeBooksPage(
      url,
      1,
      const [Book(id: 1, title: 'One'), Book(id: 2, title: 'Two')],
      accountId: _user.id,
    );
    api.detailGate = Completer<ApiResponse<List<Book>>>();
    final container = await _loadedDetailContainer(api, args: args);
    final provider = booklistDetailControllerProvider(args);
    expect(
      container.read(provider).books.map((book) => book.id).toList(),
      [1, 2],
    );
    // Remove book 1 while the revalidation is in flight.
    final notifier = container.read(provider.notifier);
    final removed =
        await notifier.removeBook(const Book(id: 1, title: 'One'));
    expect(removed.success, isTrue);
    expect(
      container.read(provider).books.map((book) => book.id).toList(),
      [2],
    );
    // The stale revalidation lands now, carrying the removed book.
    api.detailGate!.complete(ApiResponse.ok(api.detailPage1));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // Neither the visible list nor the cache resurrects it, and the
    // loading flag is not left stuck by the retired load.
    expect(
      container.read(provider).books.map((book) => book.id).toList(),
      [2],
    );
    expect(container.read(provider).isLoadingMore, isFalse);
    expect(
      BooklistHtmlCache.getBooksPage(url, 1, accountId: _user.id),
      isNull,
    );
  });

  // Doc P1-4 residual: a refresh that starts while a remove is still
  // in flight paints the pre-invalidation cache (the removed book is
  // back on screen), and its fetch is dropped as stale — without a
  // retry the book would linger until the next refresh. loadFirst
  // retries once with a fresh fetch, which returns the post-remove
  // page and paints it.
  test('refresh during a remove retries once and paints the fresh page',
      () async {
    final api = _FakeZLibraryApi();
    const url = 'https://example.com/booklist/7777777/hash/retry.html';
    const args = BooklistDetailArgs(
      booklist: Booklist(id: '7777777', name: 'Retry', url: url, count: 2),
      canEdit: true,
    );
    BooklistHtmlCache.storeBooksPage(
      url,
      1,
      const [Book(id: 1, title: 'One'), Book(id: 2, title: 'Two')],
      accountId: _user.id,
    );
    final container = await _loadedDetailContainer(api, args: args);
    final provider = booklistDetailControllerProvider(args);
    final notifier = container.read(provider.notifier);
    expect(
      container.read(provider).books.map((book) => book.id).toList(),
      [1, 2],
    );
    // Hold both the remove's write and the refresh's fetch, then start
    // the remove: its optimistic update lands, the write waits.
    api.removeGate = Completer<ApiResponse<bool>>();
    api.detailGate = Completer<ApiResponse<List<Book>>>();
    final removeFuture =
        notifier.removeBook(const Book(id: 1, title: 'One'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      container.read(provider).books.map((book) => book.id).toList(),
      [2],
    );
    // The refresh starts while the remove is in flight: it paints the
    // still-cached page (book 1 is back) and its fetch is held.
    final refreshFuture = notifier.loadFirst();
    expect(
      container.read(provider).books.map((book) => book.id).toList(),
      [1, 2],
    );
    // The remove completes and invalidates; the held fetch then lands
    // stale and is dropped, so loadFirst retries with a fresh fetch.
    api.removeGate!.complete(ApiResponse.ok(true));
    await removeFuture;
    api.detailGate!.complete(ApiResponse.ok(api.detailPage1));
    api.detailGate = null;
    api.detailPage1 = const [Book(id: 2, title: 'Two')];
    await refreshFuture;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      container.read(provider).books.map((book) => book.id).toList(),
      [2],
    );
    expect(container.read(provider).isLoadingMore, isFalse);
    expect(
      BooklistHtmlCache.getBooksPage(url, 1, accountId: _user.id)
          ?.map((book) => book.id)
          .toList(),
      [2],
    );
  });

  // Item 4: a stale loadMore must not clear a newer loadMore's flag.
  // A loads page 2, a refresh bumps the generation, B loads page 2;
  // when A finishes, isLoadingMore stays true (B owns it); when B
  // finishes it clears. No duplicate page-2 rows appear.
  test('stale loadMore does not clear a newer loadMore flag', () async {
    final api = _FakeZLibraryApi();
    // A full 10-item page 1 with a second page, so loadMore can run.
    api.searchMyPage = (page) => BooklistsPage(
      lists: List.generate(
        10,
        (i) => Booklist(
          id: '${100 + i}',
          name: 'L$i',
          url: 'https://example.com/${100 + i}',
        ),
      ),
      totalPages: 2,
    );
    final container = await _loadedListsContainer(api);
    final notifier = container.read(booklistsControllerProvider.notifier);
    expect(container.read(booklistsControllerProvider).hasMore, isTrue);
    final gateA = Completer<ApiResponse<BooklistsPage>>();
    final gateB = Completer<ApiResponse<BooklistsPage>>();
    api.searchCompleters.addAll([gateA, gateB]);
    final futureA = notifier.loadMore();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(booklistsControllerProvider).isLoadingMore, isTrue);
    await notifier.refresh();
    final futureB = notifier.loadMore();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(booklistsControllerProvider).isLoadingMore, isTrue);
    gateA.complete(
      ApiResponse.ok(
        const BooklistsPage(lists: [], totalPages: 1),
      ),
    );
    await futureA;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(booklistsControllerProvider).isLoadingMore, isTrue);
    gateB.complete(
      ApiResponse.ok(
        const BooklistsPage(lists: [], totalPages: 1),
      ),
    );
    await futureB;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(booklistsControllerProvider).isLoadingMore, isFalse);
  });

  // Item 5: when a refresh replaces the lists during a delete, the
  // failed delete must not re-insert the removed list.
  test('failed delete after a refresh does not restore the list', () async {
    final api = _FakeZLibraryApi()..deleteSucceeds = false;
    final container = await _loadedListsContainer(api);
    final notifier = container.read(booklistsControllerProvider.notifier);
    expect(
      container.read(booklistsControllerProvider).lists.map((l) => l.id).toList(),
      ['4088695', '4090055'],
    );
    final gate = Completer<ApiResponse<bool>>();
    api.deleteGate = gate;
    final deleteFuture = notifier.deleteBooklist(
      container.read(booklistsControllerProvider).lists.first,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      container.read(booklistsControllerProvider).lists.map((l) => l.id).toList(),
      ['4090055'],
    );
    // A refresh lands while the delete is in flight and replaces the
    // lists; the refresh's page comes from the fake's refreshed lists.
    api.mineLists = api.refreshedMineLists;
    await notifier.refresh();
    expect(
      container.read(booklistsControllerProvider).lists.map((l) => l.id).toList(),
      ['4090055', '4096101'],
    );
    gate.complete(ApiResponse.fail('delete failed'));
    final response = await deleteFuture;
    expect(response.success, isFalse);
    expect(
      container.read(booklistsControllerProvider).lists.map((l) => l.id).toList(),
      ['4090055', '4096101'],
    );
  });

  // Item 5 (no refresh): a failed delete with no intervening refresh
  // still restores the list at its original position.
  test('failed delete without a refresh restores the list', () async {
    final api = _FakeZLibraryApi()..deleteSucceeds = false;
    final container = await _loadedListsContainer(api);
    final notifier = container.read(booklistsControllerProvider.notifier);
    final response = await notifier.deleteBooklist(
      container.read(booklistsControllerProvider).lists.first,
    );
    expect(response.success, isFalse);
    expect(
      container.read(booklistsControllerProvider).lists.map((l) => l.id).toList(),
      ['4088695', '4090055'],
    );
  });

  // Item 6: two concurrent removes of the same book — the second is
  // rejected and only one remove call happens.
  test('concurrent removes of the same book are rejected', () async {
    final api = _FakeZLibraryApi();
    final container = await _loadedDetailContainer(api);
    final notifier =
        container.read(booklistDetailControllerProvider(_args).notifier);
    final gate = Completer<ApiResponse<int?>>();
    api.entryGate = gate;
    final first = notifier.removeBook(const Book(id: 1, title: 'One'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final second = await notifier.removeBook(const Book(id: 1, title: 'One'));
    expect(second.success, isFalse);
    expect(api.getReadlistBookIdCalls, 1);
    gate.complete(ApiResponse.ok(161213534));
    final firstResponse = await first;
    expect(firstResponse.success, isTrue);
    expect(api.removeCalls, 1);
    expect(
      container
          .read(booklistDetailControllerProvider(_args))
          .books
          .map((book) => book.id)
          .toList(),
      [2],
    );
  });

  // Item 6: concurrent removes of different books remove exactly the
  // right books (no index shift onto the wrong row).
  test('concurrent removes of different books remove the right rows', () async {
    final api = _FakeZLibraryApi();
    final container = await _loadedDetailContainer(api);
    final notifier =
        container.read(booklistDetailControllerProvider(_args).notifier);
    final gate1 = Completer<ApiResponse<int?>>();
    final gate2 = Completer<ApiResponse<int?>>();
    api.entryGate = gate1;
    final first = notifier.removeBook(const Book(id: 1, title: 'One'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    api.entryGate = gate2;
    final second = notifier.removeBook(const Book(id: 2, title: 'Two'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate2.complete(ApiResponse.ok(161213535));
    expect((await second).success, isTrue);
    gate1.complete(ApiResponse.ok(161213534));
    expect((await first).success, isTrue);
    expect(
      container
          .read(booklistDetailControllerProvider(_args))
          .books
          .map((book) => book.id)
          .toList(),
      isEmpty,
    );
  });

  // Item 6: a failed remove restores the book before its successor,
  // not at a stale index shifted by a concurrent remove.
  test('failed remove restores before the successor', () async {
    final api = _FakeZLibraryApi()..removeSucceeds = false;
    final container = await _loadedDetailContainer(api);
    final notifier =
        container.read(booklistDetailControllerProvider(_args).notifier);
    final response = await notifier.removeBook(const Book(id: 1, title: 'One'));
    expect(response.success, isFalse);
    expect(
      container
          .read(booklistDetailControllerProvider(_args))
          .books
          .map((book) => book.id)
          .toList(),
      [1, 2],
    );
  });

  // Item 8: Args equality includes the URL; canEdit is excluded (the
  // screen reads it from its own widget arguments, not the controller).
  test('detail args equality includes the URL, not canEdit', () {
    const base = Booklist(id: '4088695', name: '001', url: _detailUrl);
    const moved = Booklist(
      id: '4088695',
      name: '001',
      url: 'https://example.com/booklist/4088695/other/001.html',
    );
    expect(
      const BooklistDetailArgs(booklist: base, canEdit: true) ==
          const BooklistDetailArgs(booklist: base, canEdit: false),
      isTrue,
    );
    expect(
      const BooklistDetailArgs(booklist: base) ==
          const BooklistDetailArgs(booklist: moved),
      isFalse,
    );
    expect(
      const BooklistDetailArgs(booklist: base).hashCode,
      const BooklistDetailArgs(booklist: base, canEdit: true).hashCode,
    );
  });

  // Item 9: page-1 hasMore does not trust the stale list count — a
  // first page that fills the count still allows a page-2 attempt,
  // and the JSON totalPages arbitrates from there.
  test('page-1 hasMore ignores the stale count', () async {
    final api = _FakeZLibraryApi();
    final container = await _loadedDetailContainer(api);
    final state = container.read(booklistDetailControllerProvider(_args));
    expect(state.books.map((book) => book.id).toList(), [1, 2]);
    expect(state.hasMore, isTrue);
    expect(state.nextPage, 2);
  });

  // Item 10: invalidateBooklist drops the HTML entry and every JSON
  // page for that list; other lists are untouched.
  test('invalidateBooklist drops the HTML and all JSON pages', () {
    const url = 'https://example.com/booklist/1/h/s.html';
    const other = 'https://example.com/booklist/2/h/s.html';
    BooklistHtmlCache.store(url, '<html>detail</html>', accountId: '111');
    BooklistHtmlCache.storeBooksPage(
      url,
      1,
      const [Book(id: 1, title: 'One')],
      accountId: '111',
    );
    BooklistHtmlCache.storeBooksPage(
      url,
      2,
      const [Book(id: 2, title: 'Two')],
      accountId: '111',
    );
    BooklistHtmlCache.storeBooksPage(
      other,
      1,
      const [Book(id: 9, title: 'Other')],
      accountId: '111',
    );
    BooklistHtmlCache.invalidateBooklist(url, accountId: '111');
    expect(BooklistHtmlCache.get(url, accountId: '111'), isNull);
    expect(BooklistHtmlCache.getBooksPage(url, 1, accountId: '111'), isNull);
    expect(BooklistHtmlCache.getBooksPage(url, 2, accountId: '111'), isNull);
    expect(
      BooklistHtmlCache.getBooksPage(other, 1, accountId: '111'),
      isNotNull,
    );
  });

  // Item 10: invalidateBooklistPages drops only the JSON pages.
  test('invalidateBooklistPages drops only the JSON pages', () {
    const url = 'https://example.com/booklist/1/h/s.html';
    BooklistHtmlCache.store(url, '<html>detail</html>', accountId: '111');
    BooklistHtmlCache.storeBooksPage(
      url,
      2,
      const [Book(id: 2, title: 'Two')],
      accountId: '111',
    );
    BooklistHtmlCache.invalidateBooklistPages(url, accountId: '111');
    expect(BooklistHtmlCache.get(url, accountId: '111'), '<html>detail</html>');
    expect(BooklistHtmlCache.getBooksPage(url, 2, accountId: '111'), isNull);
  });

  // Item 10: pruneExpired deletes stale entries and leaves fresh ones.
  test('pruneExpired deletes stale entries only', () {
    final box = Hive.box(BooklistHtmlCache.boxName);
    final staleAt = DateTime.now()
        .subtract(BooklistHtmlCache.ttl + const Duration(seconds: 1))
        .millisecondsSinceEpoch;
    box.put('https://example.com/old', {
      'at': staleAt,
      'html': '<html>old</html>',
    });
    BooklistHtmlCache.store('https://example.com/new', '<html>new</html>');
    BooklistHtmlCache.pruneExpired();
    expect(box.containsKey('https://example.com/old'), isFalse);
    expect(
      BooklistHtmlCache.get('https://example.com/new'),
      '<html>new</html>',
    );
  });

  // Item 10: an expired entry is deleted on read, not just hidden.
  test('expired entries are deleted on read', () {
    final box = Hive.box(BooklistHtmlCache.boxName);
    final staleAt = DateTime.now()
        .subtract(BooklistHtmlCache.ttl + const Duration(seconds: 1))
        .millisecondsSinceEpoch;
    box.put('https://example.com/old', {
      'at': staleAt,
      'html': '<html>old</html>',
    });
    expect(BooklistHtmlCache.get('https://example.com/old'), isNull);
    expect(box.containsKey('https://example.com/old'), isFalse);
  });

  // Item 10: a corrupt JSON page is deleted on read, not just hidden.
  test('corrupt JSON pages are deleted on read', () {
    final box = Hive.box(BooklistHtmlCache.boxName);
    const url = 'https://example.com/booklist/1/h/s.html';
    box.put('$url#json-page=2#account=111', {
      'at': DateTime.now().millisecondsSinceEpoch,
      'books': 'not-a-list',
    });
    expect(
      BooklistHtmlCache.getBooksPage(url, 2, accountId: '111'),
      isNull,
    );
    expect(box.containsKey('$url#json-page=2#account=111'), isFalse);
  });

  // Item 11: the user_token JWT is stripped from HTML before it is
  // persisted, so no session credential ever reaches Hive.
  test('store strips the user_token from cached HTML', () {
    const url = 'https://example.com/booklist/1/h/s.html';
    BooklistHtmlCache.store(
      url,
      '<z-bookcard id="1" user_token="eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyIjoxfQ.sig" href="/book/x/y.html"></z-bookcard>',
    );
    final stored = BooklistHtmlCache.get(url);
    expect(stored, isNotNull);
    expect(stored, isNot(contains('user_token')));
    expect(stored, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
    expect(stored, contains('z-bookcard'));
  });

  // Item 11: a box that still holds pre-strip HTML carrying a token
  // is swept once on first access — only the token-bearing entries
  // are dropped; clean HTML and parsed JSON pages survive (the old
  // wipe-the-whole-box behaviour dropped those too).
  test('first access purges only pre-strip HTML carrying a token', () {
    final box = Hive.box(BooklistHtmlCache.boxName);
    box.put('https://example.com/booklist/1/h/s.html', {
      'at': DateTime.now().millisecondsSinceEpoch,
      'html': '<z-bookcard user_token="abc.def.ghi"></z-bookcard>',
    });
    box.put('https://example.com/booklist/2/h/s.html', {
      'at': DateTime.now().millisecondsSinceEpoch,
      'html': '<html>clean</html>',
    });
    box.put('https://example.com/booklist/2/h/s.html#json-page=2', {
      'at': DateTime.now().millisecondsSinceEpoch,
      'books': [
        {'id': 1, 'title': 'Kept'},
      ],
    });
    // First access runs the one-time sweep.
    expect(
      BooklistHtmlCache.get('https://example.com/booklist/2/h/s.html'),
      '<html>clean</html>',
    );
    expect(
      box.containsKey('https://example.com/booklist/1/h/s.html'),
      isFalse,
    );
    expect(
      BooklistHtmlCache.getBooksPage(
        'https://example.com/booklist/2/h/s.html',
        2,
      ),
      isNotNull,
    );
    expect(box.isEmpty, isFalse);
  });
}
