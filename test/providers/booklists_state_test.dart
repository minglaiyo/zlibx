// P2-4 regression tests (zlibx-3 review): booklist list pagination and
// cache state invariants for BooklistsController.
//
// The controller's generation/token machinery is what keeps a stale
// response from overwriting the list the user is looking at. These
// tests pin that behaviour down for the tab switch, the query/order
// change, a loadMore racing a refresh, a cache hit followed by a
// failed background refresh, and an account switch.
//
// Follows test/services/booklist_gpt_fixes_test.dart's harness: a fake
// ZLibraryApi (implements + noSuchMethod), a fake AuthNotifier, a
// throwaway Hive directory, and a ProviderContainer that listens to
// the controller so the autoDispose notifier stays alive.
//
// Skipped (already covered):
// - (e) an old loadMore finishing after a newer loadMore started must
//   not clear the newer loadMore's flag: covered by 'stale loadMore
//   does not clear a newer loadMore flag' in
//   test/services/booklist_gpt_fixes_test.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/booklists_provider.dart';
import 'package:zlibx/providers/cache_invalidation.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/booklist_html_cache.dart';

const _userA = User(
  id: '35899435',
  email: 'a@example.com',
  name: 'userA',
  remixUserkey: 'keyA',
);
const _userB = User(
  id: '99999999',
  email: 'b@example.com',
  name: 'userB',
  remixUserkey: 'keyB',
);

class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(this._state);

  AuthState _state;

  @override
  AuthState build() => _state;

  void setUser(User? user) {
    _state = AuthState(user: user);
    state = _state;
  }
}

Booklist _list(String id) => Booklist(
      id: id,
      name: 'List $id',
      url: 'https://example.com/booklist/$id',
    );

/// Canned mine pages. The default query returns two 10-item pages
/// (totalPages 2, so page 1 hasMore); a changed query/order returns a
/// short, distinguishable page so a stale append is visible.
BooklistsPage _minePage(String query, String? order, int page) {
  if (query == 'new query') {
    return BooklistsPage(lists: [_list('300'), _list('301')], totalPages: 1);
  }
  if (order == 'date_created' && page == 1) {
    return BooklistsPage(lists: [_list('400'), _list('401')], totalPages: 1);
  }
  if (page == 1) {
    return BooklistsPage(
      lists: List.generate(10, (i) => _list('${100 + i}')),
      totalPages: 2,
    );
  }
  return BooklistsPage(
    lists: List.generate(10, (i) => _list('${200 + i}')),
    totalPages: 2,
  );
}

class _FakeZLibraryApi implements ZLibraryApi {
  /// Single-use gate for the next mine page-1 fetch. Set by the test
  /// before the fetch it wants to hold; cleared when consumed.
  Completer<ApiResponse<BooklistsPage>>? searchMyGate;

  /// Ordered gates for mine page>1 fetches (loadMore), consumed in order.
  final searchCompleters = <Completer<ApiResponse<BooklistsPage>>>[];

  /// When true, every mine search fails with a plain (non-challenge)
  /// error, so the controller reports the failure instead of falling
  /// back to the WebView solver.
  bool failSearchMy = false;

  int searchMyCalls = 0;
  final searchMyPages = <int>[];
  int searchPublicCalls = 0;

  @override
  Future<ApiResponse<BooklistsPage>> searchMyBooklists({
    String query = '',
    String? order,
    int page = 1,
  }) async {
    searchMyCalls++;
    searchMyPages.add(page);
    if (failSearchMy) return ApiResponse.fail('network error');
    if (page == 1 && searchMyGate != null) {
      final gate = searchMyGate;
      searchMyGate = null;
      return gate!.future;
    }
    if (page > 1 && searchCompleters.isNotEmpty) {
      return searchCompleters.removeAt(0).future;
    }
    return ApiResponse.ok(_minePage(query, order, page));
  }

  @override
  Future<ApiResponse<BooklistsPage>> searchPublicBooklists({
    String query = '',
    String? order,
    int page = 1,
  }) async {
    searchPublicCalls++;
    return ApiResponse.ok(
      BooklistsPage(lists: [_list('900'), _list('901')], totalPages: 1),
    );
  }

  @override
  String booklistsPageUrl({
    required bool mine,
    String query = '',
    String? order,
    int page = 1,
  }) =>
      mine
          ? 'https://example.com/booklists/my?page=$page'
          : 'https://example.com/booklists?page=$page';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected call: ${invocation.memberName}');
}

/// Minimal cached `/booklists/my` page (two lists), modelled on
/// test/parsers/booklist_page_test.dart's fixture. The URL must match
/// the fake's booklistsPageUrl output for mine page 1.
const _cachedMineHtml = '''
<html><body>
<z-booklist id="4088695" href="/booklist/4088695/62a0c2/001.html" topic="Cached One" quantity="2"></z-booklist>
<z-booklist id="4090055" href="/booklist/4090055/62a0c2/002.html" topic="Cached Two" quantity="1"></z-booklist>
<script>var pagerOptions = {pagesTotal: 1};</script>
</body></html>
''';

const _cachedMineUrl = 'https://example.com/booklists/my?page=1';

/// Captures a [Ref] so a test can call the real account-switch path
/// ([invalidateAccountScopedProviders]) instead of only invalidating
/// one provider by hand.
final _refCaptureProvider = Provider<Ref>((ref) => ref);

ProviderContainer _container(_FakeZLibraryApi api, {User? user}) {
  final container = ProviderContainer(
    overrides: [
      zlibraryApiProvider.overrideWithValue(api),
      authProvider.overrideWith(
        () => _FakeAuthNotifier(AuthState(user: user ?? _userA)),
      ),
    ],
  );
  container.listen(booklistsControllerProvider, (_, _) {});
  addTearDown(container.dispose);
  return container;
}

Future<ProviderContainer> _loadedContainer(
  _FakeZLibraryApi api, {
  User? user,
}) async {
  final container = _container(api, user: user);
  await _waitForList(
    container,
    (s) => s.phase == BooklistsPhase.ready && s.lists.isNotEmpty,
  );
  return container;
}

List<String> _ids(ProviderContainer container) => container
    .read(booklistsControllerProvider)
    .lists
    .map((l) => l.id)
    .toList();

/// Polls until [condition] holds (the loadFirst/setTab/search paths
/// are fire-and-forget, so there is no future to await). Same shape
/// as _waitForIds in test/services/booklist_gpt_fixes_test.dart.
Future<void> _waitForList(
  ProviderContainer container,
  bool Function(BooklistsState state) condition,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    if (condition(container.read(booklistsControllerProvider))) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(
    'timed out waiting for booklists state; '
    'state=${container.read(booklistsControllerProvider)}',
  );
}

Future<void> _pump() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('booklists_state_test');
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

  test('(a) stale mine response does not overwrite the discover tab',
      () async {
    final api = _FakeZLibraryApi();
    final container = await _loadedContainer(api);
    final notifier = container.read(booklistsControllerProvider.notifier);
    expect(_ids(container), List.generate(10, (i) => '${100 + i}'));

    // Hold the mine refresh's page-1 fetch on a gate.
    final mineGate = Completer<ApiResponse<BooklistsPage>>();
    api.searchMyGate = mineGate;
    final refresh = notifier.refresh();
    // While the mine refresh is in flight, switch to discover.
    notifier.setTab(BooklistTab.discover);
    await _waitForList(
      container,
      (s) => s.tab == BooklistTab.discover && s.lists.length == 2,
    );
    expect(_ids(container), ['900', '901']);
    expect(api.searchPublicCalls, 1);

    // Release the stale mine response.
    mineGate.complete(ApiResponse.ok(_minePage('', 'popular', 1)));
    await refresh;
    await _pump();
    // The stale mine page must NOT have overwritten the discover lists.
    final state = container.read(booklistsControllerProvider);
    expect(state.tab, BooklistTab.discover);
    expect(_ids(container), ['900', '901']);
  });

  test('(b) changing the search query drops the old page-2 loadMore',
      () async {
    final api = _FakeZLibraryApi();
    final container = await _loadedContainer(api);
    final notifier = container.read(booklistsControllerProvider.notifier);
    expect(_ids(container), List.generate(10, (i) => '${100 + i}'));

    // Hold the page-2 loadMore on a gate.
    final page2Gate = Completer<ApiResponse<BooklistsPage>>();
    api.searchCompleters.add(page2Gate);
    final loadMore = notifier.loadMore();
    // Change the query while the old page-2 fetch is in flight.
    notifier.search('new query');
    await _waitForList(
      container,
      (s) => s.query == 'new query' && s.lists.length == 2,
    );
    expect(_ids(container), ['300', '301']);

    // Release the stale page-2 response (old query's page 2).
    page2Gate.complete(ApiResponse.ok(_minePage('', 'popular', 2)));
    await loadMore;
    await _pump();
    // The old page-2 rows must NOT have appended to the new query's list.
    final state = container.read(booklistsControllerProvider);
    expect(state.query, 'new query');
    expect(_ids(container), ['300', '301']);
    expect(state.nextPage, 2);
  });

  test('(b) changing the sort order drops the old page-2 loadMore', () async {
    final api = _FakeZLibraryApi();
    final container = await _loadedContainer(api);
    final notifier = container.read(booklistsControllerProvider.notifier);
    expect(_ids(container), List.generate(10, (i) => '${100 + i}'));

    final page2Gate = Completer<ApiResponse<BooklistsPage>>();
    api.searchCompleters.add(page2Gate);
    final loadMore = notifier.loadMore();
    notifier.setOrder('date_created');
    await _waitForList(
      container,
      (s) => s.order == 'date_created' && s.lists.length == 2,
    );
    expect(_ids(container), ['400', '401']);

    page2Gate.complete(ApiResponse.ok(_minePage('', 'popular', 2)));
    await loadMore;
    await _pump();
    final state = container.read(booklistsControllerProvider);
    expect(state.order, 'date_created');
    expect(_ids(container), ['400', '401']);
    expect(state.nextPage, 2);
  });

  test(
      '(c) loadMore during a refresh requests the page once and appends once',
      () async {
    final api = _FakeZLibraryApi();
    final container = await _loadedContainer(api);
    final notifier = container.read(booklistsControllerProvider.notifier);
    expect(_ids(container), List.generate(10, (i) => '${100 + i}'));

    // Hold the refresh's page-1 fetch on a gate.
    final mineGate = Completer<ApiResponse<BooklistsPage>>();
    api.searchMyGate = mineGate;
    final refresh = notifier.refresh();
    // While the refresh is in flight, loadMore page 2 (held on its
    // own gate). A page-1 refresh does not set isLoadingMore, so the
    // loadMore is not blocked by design — it shares the refresh's
    // generation and both responses are current.
    final page2Gate = Completer<ApiResponse<BooklistsPage>>();
    api.searchCompleters.add(page2Gate);
    final loadMore = notifier.loadMore();
    expect(
      container.read(booklistsControllerProvider).isLoadingMore,
      isTrue,
    );

    // Release the refresh first, then the page-2 fetch.
    mineGate.complete(ApiResponse.ok(_minePage('', 'popular', 1)));
    await refresh;
    page2Gate.complete(ApiResponse.ok(_minePage('', 'popular', 2)));
    await loadMore;
    await _pump();

    final state = container.read(booklistsControllerProvider);
    expect(_ids(container), [
      ...List.generate(10, (i) => '${100 + i}'),
      ...List.generate(10, (i) => '${200 + i}'),
    ]);
    expect(state.nextPage, 3);
    expect(state.hasMore, isFalse);
    // The same page must not have been requested twice.
    expect(api.searchMyPages.where((p) => p == 2).length, 1);
  });

  test(
      '(d) cache hit followed by a failed background refresh keeps the old list',
      () async {
    final api = _FakeZLibraryApi()..failSearchMy = true;
    // Seed the mine page-1 cache for user A.
    BooklistHtmlCache.store(
      _cachedMineUrl,
      _cachedMineHtml,
      accountId: _userA.id,
    );
    final container = _container(api);
    // The cached page paints instantly; the background refresh fails.
    await _waitForList(
      container,
      (s) => s.phase == BooklistsPhase.ready && s.lists.length == 2,
    );
    // Wait for the background refresh to run and fail.
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (api.searchMyCalls == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(api.searchMyCalls, greaterThanOrEqualTo(1));
    await _pump();
    // The old (cached) lists are kept, not cleared, and no error is shown.
    final state = container.read(booklistsControllerProvider);
    expect(state.phase, BooklistsPhase.ready);
    expect(_ids(container), ['4088695', '4090055']);
    expect(state.error, isNull);
  });

  test(
      '(f) a fresh load under account B does not paint account A cached mine page',
      () async {
    final api = _FakeZLibraryApi();
    // Seed A's cached mine page.
    BooklistHtmlCache.store(
      _cachedMineUrl,
      _cachedMineHtml,
      accountId: _userA.id,
    );
    // Load as A (paints A's cached page), then switch to B and reload.
    final container = _container(api);
    await _waitForList(
      container,
      (s) => s.phase == BooklistsPhase.ready && s.lists.length == 2,
    );
    expect(_ids(container), ['4088695', '4090055']);

    final authNotifier =
        container.read(authProvider.notifier) as _FakeAuthNotifier;
    authNotifier.setUser(_userB);
    // The controller is autoDispose; invalidating it simulates the
    // fresh load a rebuild/navigation would do under B.
    container.invalidate(booklistsControllerProvider);
    container.listen(booklistsControllerProvider, (_, _) {});
    await _waitForList(
      container,
      (s) => s.phase == BooklistsPhase.ready && s.lists.length == 10,
    );
    // B's lists come from the network (the fake), NOT from A's cache.
    expect(_ids(container), List.generate(10, (i) => '${100 + i}'));
  });

  test(
      '(f) account switch reloads the controller under the new account',
      () async {
    final api = _FakeZLibraryApi();
    // Seed A's cached mine page so A's lists are distinguishable.
    BooklistHtmlCache.store(
      _cachedMineUrl,
      _cachedMineHtml,
      accountId: _userA.id,
    );
    final container = _container(api);
    // Load as A (paints A's cached page).
    await _waitForList(
      container,
      (s) => s.phase == BooklistsPhase.ready && s.lists.length == 2,
    );
    expect(_ids(container), ['4088695', '4090055']);

    // Switch the account the way the real AuthNotifier does: the
    // switch invalidates every account-scoped provider, including
    // this controller, so it reloads under B instead of keeping A's
    // lists on screen.
    final authNotifier =
        container.read(authProvider.notifier) as _FakeAuthNotifier;
    authNotifier.setUser(_userB);
    invalidateAccountScopedProviders(container.read(_refCaptureProvider));
    await _waitForList(
      container,
      (s) => s.phase == BooklistsPhase.ready && s.lists.length == 10,
    );
    // B's lists come from the network (the fake), NOT from A's cache.
    expect(_ids(container), List.generate(10, (i) => '${100 + i}'));
  });
}
