import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../services/booklist_repository.dart';
import 'auth_provider.dart';
import 'zlibrary_provider.dart';

enum BooklistTab { mine, discover }

/// What the booklists screen should show.
enum BooklistsPhase { loading, loggedOut, error, ready }

class BooklistsState {
  final BooklistTab tab;
  final String query;

  /// List sort order sent as the `order` query parameter (`popular`,
  /// `date_created`, `date_updated` — the values the site's own list
  /// pages use). Applies to both tabs.
  final String order;
  final BooklistsPhase phase;
  final List<Booklist> lists;
  final int nextPage;
  final bool hasMore;
  final bool isLoadingMore;
  final String? error;

  const BooklistsState({
    this.tab = BooklistTab.mine,
    this.query = '',
    this.order = 'popular',
    this.phase = BooklistsPhase.loading,
    this.lists = const [],
    this.nextPage = 1,
    this.hasMore = true,
    this.isLoadingMore = false,
    this.error,
  });

  BooklistsState copyWith({
    BooklistTab? tab,
    String? query,
    String? order,
    BooklistsPhase? phase,
    List<Booklist>? lists,
    int? nextPage,
    bool? hasMore,
    bool? isLoadingMore,
    String? error,
    bool clearError = false,
  }) {
    return BooklistsState(
      tab: tab ?? this.tab,
      query: query ?? this.query,
      order: order ?? this.order,
      phase: phase ?? this.phase,
      lists: lists ?? this.lists,
      nextPage: nextPage ?? this.nextPage,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Own booklists + public booklists to discover, with search and paging.
///
/// List pages are the site's HTML (`/booklists`, `/booklists/my`). A
/// cached page paints instantly and is revalidated in the background
/// (a failed background refresh keeps the cached lists); when Dio hits
/// the browser-check wall the same page is fetched via the WebView
/// solver. Fetching, parsing, the page cache and invalidation live in
/// [BooklistRepository]; this controller keeps the state machine.
class BooklistsController extends AutoDisposeNotifier<BooklistsState> {
  static const int _pageSize = 10;

  bool _alive = true;

  /// Bumped by every fresh load (tab switch, search, retry, refresh);
  /// every in-flight load carries the generation it started with, and a
  /// slower response for an old tab/query is dropped.
  int _generation = 0;

  /// Tab/query/order of the lists currently painted (recorded in
  /// [_applyPage]). A reload for the SAME key must not blank them —
  /// see [loadFirst].
  BooklistTab? _paintedTab;
  String _paintedQuery = '';
  String _paintedOrder = '';

  /// Identity of the loadMore currently holding the [BooklistsState.isLoadingMore]
  /// flag (0 = none). A stale loadMore's `finally` must not clear a
  /// newer loadMore's flag — only the holder may release it.
  int _loadMoreToken = 0;
  int _loadMoreOwner = 0;

  /// Data layer: fetching, parsing, the page cache and invalidation
  /// (see [BooklistRepository]). Holds no state of its own; rebuilt on
  /// every (re)build from the shared API instance.
  late BooklistRepository _repository;

  @override
  BooklistsState build() {
    _repository = BooklistRepository(ref.read(zlibraryApiProvider));
    _alive = true;
    ref.onDispose(() => _alive = false);
    Future<void>.microtask(loadFirst);
    return const BooklistsState();
  }

  bool _isCurrent(int generation) => _alive && generation == _generation;

  /// Cache partition: the own-lists tab is account-scoped (the same URL
  /// serves another account's lists after a switch); discover is public.
  String? _accountIdFor(BooklistTab tab) => tab == BooklistTab.mine
      ? (ref.read(authProvider).user?.id ?? 'signed-out')
      : null;

  void setTab(BooklistTab tab) {
    if (tab == state.tab) return;
    state = state.copyWith(tab: tab);
    unawaited(loadFirst());
  }

  void search(String query) {
    final trimmed = query.trim();
    if (trimmed == state.query) return;
    state = state.copyWith(query: trimmed);
    unawaited(loadFirst());
  }

  /// Change the list sort order and reload page 1. [order] is one of
  /// `popular`, `date_created`, `date_updated`.
  void setOrder(String order) {
    if (order == state.order) return;
    state = state.copyWith(order: order);
    unawaited(loadFirst());
  }

  /// Delete one of the user's own lists (mine tab only): optimistic
  /// removal, restored on failure. Returns the API response so the
  /// caller can show the failure message; the guard cases return a
  /// failure response and change nothing.
  ///
  /// The restore is guarded by the generation captured at delete
  /// start: a refresh that ran during the delete owns the
  /// authoritative list, so a stale restore must not re-insert a
  /// list the refresh already dropped (or duplicate one it kept).
  Future<ApiResponse<bool>> deleteBooklist(Booklist list) async {
    if (state.tab != BooklistTab.mine ||
        state.phase != BooklistsPhase.ready) {
      return ApiResponse.fail('delete booklist not available');
    }
    final index = state.lists.indexWhere((l) => l.id == list.id);
    if (index < 0) return ApiResponse.fail('delete booklist not available');
    final listId = int.tryParse(list.id);
    if (listId == null) {
      return ApiResponse.fail('delete booklist not available');
    }
    final generation = _generation;
    final removed = state.lists[index];
    state = state.copyWith(
      lists: [...state.lists]..removeAt(index),
    );
    try {
      final response = await _repository.deleteBooklist(listId);
      if (!_alive) return response;
      if (response.success) {
        // The list is already gone from the visible page (optimistic
        // removal above). Invalidate the cached mine page and the
        // deleted list's detail page so a later refresh cannot repaint
        // the stale page with the list back in it — that repaint is
        // what made a delete look slow. No reload: there is nothing
        // left to fetch.
        _invalidateMinePage();
        _repository.invalidateBooklist(
          list.url,
          accountId: _accountIdFor(BooklistTab.mine),
        );
        return response;
      }
      _restoreDeleted(generation, removed, index);
      return response;
    } catch (_) {
      if (!_alive) return ApiResponse.fail('delete booklist failed');
      _restoreDeleted(generation, removed, index);
      return ApiResponse.fail('delete booklist failed');
    }
  }

  /// Re-inserts a list whose delete failed — only when the list has
  /// not been replaced since the delete started (a refresh owns the
  /// authoritative list then) and the list is not already present.
  void _restoreDeleted(int generation, Booklist removed, int index) {
    if (!_isCurrent(generation)) return;
    if (state.lists.any((item) => item.id == removed.id)) return;
    state = state.copyWith(
      lists: [...state.lists]
        ..insert(index.clamp(0, state.lists.length), removed),
    );
  }

  /// A book was added to one of the user's lists (from the
  /// add-to-booklist picker): bump that list's count optimistically
  /// so the booklists screen shows the new count without waiting
  /// for its next background refresh. No-op when the list is not
  /// in the currently loaded page. The rebuilt list copies every
  /// field — a hand-built constructor that drops one (color, private,
  /// favorite, …) would silently wipe that state.
  void noteBookAdded(String listId) {
    final index = state.lists.indexWhere((item) => item.id == listId);
    if (index < 0) return;
    final list = state.lists[index];
    final count = list.count;
    if (count == null) return;
    final updated = Booklist(
      id: list.id,
      name: list.name,
      description: list.description,
      author: list.author,
      authorProfile: list.authorProfile,
      authorAvatar: list.authorAvatar,
      count: count + 1,
      views: list.views,
      comments: list.comments,
      color: list.color,
      isPrivate: list.isPrivate,
      isFavorite: list.isFavorite,
      coverUrl: list.coverUrl,
      url: list.url,
      previewBooks: list.previewBooks,
    );
    final lists = [...state.lists]..[index] = updated;
    state = state.copyWith(lists: lists);
  }

  /// Replace one visible list with an updated copy (after a
  /// successful edit, color change, visibility flip or favorite
  /// toggle) without reloading the page. No-op when the list is not
  /// in the currently loaded page.
  void _replaceList(Booklist updated) {
    final index = state.lists.indexWhere((item) => item.id == updated.id);
    if (index < 0) return;
    final lists = [...state.lists]..[index] = updated;
    state = state.copyWith(lists: lists);
  }

  /// Invalidate the cached mine list page (the URL `loadFirst` reads
  /// and writes), so a later refresh fetches fresh instead of
  /// repainting the pre-write page.
  void _invalidateMinePage() {
    _repository.invalidateBooklist(
      _repository.booklistsPageUrl(
        mine: true,
        query: state.query,
        order: state.order,
        page: 1,
      ),
      accountId: _accountIdFor(BooklistTab.mine),
    );
  }

  /// A list was just created on the account: prepend it to the visible
  /// mine page (when the mine tab is showing an unfiltered page) and
  /// invalidate the cached mine page, so a later refresh cannot repaint
  /// the pre-create page without it. The position is optimistic: under
  /// a non-date sort the next refresh settles the true order.
  void noteBooklistCreated(Booklist created) {
    _invalidateMinePage();
    if (state.tab != BooklistTab.mine ||
        state.phase != BooklistsPhase.ready ||
        state.query.isNotEmpty) {
      return;
    }
    if (state.lists.any((item) => item.id == created.id)) return;
    state = state.copyWith(lists: [created, ...state.lists]);
  }

  /// The create answer carried no list (empty body): invalidate the
  /// cached mine page and refresh it in the background, without
  /// blanking the lists already on screen.
  void refreshMineAfterCreate() {
    _invalidateMinePage();
    unawaited(loadFirst());
  }

  /// Edit one of the user's own lists (mine tab only): on success the
  /// visible entry is replaced in place and the list's cached detail
  /// pages are invalidated. Returns the API response so the caller can
  /// show the failure message. When the answer carried no updated
  /// list (empty-body success), the caller reloads instead.
  Future<ApiResponse<Booklist?>> editBooklist(
    Booklist list, {
    required String title,
    required String description,
    required bool isPrivate,
    required int? color,
  }) async {
    if (state.tab != BooklistTab.mine ||
        state.phase != BooklistsPhase.ready) {
      return ApiResponse.fail('edit booklist not available');
    }
    final listId = int.tryParse(list.id);
    if (listId == null) {
      return ApiResponse.fail('edit booklist not available');
    }
    try {
      final response = await _repository.editBooklist(
        id: listId,
        title: title,
        description: description,
        isPrivate: isPrivate,
        color: color,
      );
      if (!_alive) return response;
      final updated = response.data;
      if (response.success && updated != null) {
        _repository.invalidateBooklist(
          list.url,
          accountId: _accountIdFor(state.tab),
        );
        _replaceList(updated);
      }
      return response;
    } catch (_) {
      return ApiResponse.fail('edit booklist failed');
    }
  }

  /// Change one of the user's own lists' color (mine tab only):
  /// optimistic local update, restored on failure. The color value
  /// (0–5) is the site's own numbering.
  Future<ApiResponse<bool>> setBooklistColor(Booklist list, int color) async {
    if (state.tab != BooklistTab.mine ||
        state.phase != BooklistsPhase.ready) {
      return ApiResponse.fail('change booklist color not available');
    }
    final listId = int.tryParse(list.id);
    if (listId == null) {
      return ApiResponse.fail('change booklist color not available');
    }
    final updated = _withColor(list, color);
    _replaceList(updated);
    try {
      final response =
          await _repository.setBooklistColor(id: listId, color: color);
      if (!_alive) return response;
      if (response.success) {
        _repository.invalidateBooklist(
          list.url,
          accountId: _accountIdFor(state.tab),
        );
        return response;
      }
      _replaceList(list);
      return response;
    } catch (_) {
      if (_alive) _replaceList(list);
      return ApiResponse.fail('change booklist color failed');
    }
  }

  /// Flip one of the user's own lists between public and private (mine
  /// tab only): the server flips the current state, so the local flag
  /// is flipped optimistically and restored on failure.
  Future<ApiResponse<bool>> toggleBooklistPublic(Booklist list) async {
    if (state.tab != BooklistTab.mine ||
        state.phase != BooklistsPhase.ready) {
      return ApiResponse.fail('change booklist visibility not available');
    }
    final listId = int.tryParse(list.id);
    if (listId == null) {
      return ApiResponse.fail('change booklist visibility not available');
    }
    final updated = _withPrivate(list, !list.isPrivate);
    _replaceList(updated);
    try {
      final response = await _repository.toggleBooklistPublic(listId);
      if (!_alive) return response;
      if (response.success) {
        _repository.invalidateBooklist(
          list.url,
          accountId: _accountIdFor(state.tab),
        );
        return response;
      }
      _replaceList(list);
      return response;
    } catch (_) {
      if (_alive) _replaceList(list);
      return ApiResponse.fail('change booklist visibility failed');
    }
  }

  /// Favorite or unfavorite a booklist (either tab): optimistic local
  /// flip, restored on failure. The cached list page is left to the
  /// next background revalidation — the visible state is what the
  /// user sees.
  Future<ApiResponse<bool>> setBooklistFavorite(
    Booklist list,
    bool favorite,
  ) async {
    if (state.phase != BooklistsPhase.ready) {
      return ApiResponse.fail('favorite booklist not available');
    }
    final listId = int.tryParse(list.id);
    if (listId == null) {
      return ApiResponse.fail('favorite booklist not available');
    }
    final updated = _withFavorite(list, favorite);
    _replaceList(updated);
    try {
      final response = favorite
          ? await _repository.favoriteBooklist(listId)
          : await _repository.unfavoriteBooklist(listId);
      if (!_alive) return response;
      if (response.success) return response;
      _replaceList(list);
      return response;
    } catch (_) {
      if (_alive) _replaceList(list);
      return ApiResponse.fail('favorite booklist failed');
    }
  }

  /// Rebuild [list] with a new color, copying every other field.
  static Booklist _withColor(Booklist list, int color) => Booklist(
        id: list.id,
        name: list.name,
        description: list.description,
        author: list.author,
        authorProfile: list.authorProfile,
        authorAvatar: list.authorAvatar,
        count: list.count,
        views: list.views,
        comments: list.comments,
        color: color,
        isPrivate: list.isPrivate,
        isFavorite: list.isFavorite,
        coverUrl: list.coverUrl,
        url: list.url,
        previewBooks: list.previewBooks,
      );

  /// Rebuild [list] with a new private flag, copying every other field.
  static Booklist _withPrivate(Booklist list, bool isPrivate) => Booklist(
        id: list.id,
        name: list.name,
        description: list.description,
        author: list.author,
        authorProfile: list.authorProfile,
        authorAvatar: list.authorAvatar,
        count: list.count,
        views: list.views,
        comments: list.comments,
        color: list.color,
        isPrivate: isPrivate,
        isFavorite: list.isFavorite,
        coverUrl: list.coverUrl,
        url: list.url,
        previewBooks: list.previewBooks,
      );

  /// Rebuild [list] with a new favorite flag, copying every other field.
  static Booklist _withFavorite(Booklist list, bool isFavorite) => Booklist(
        id: list.id,
        name: list.name,
        description: list.description,
        author: list.author,
        authorProfile: list.authorProfile,
        authorAvatar: list.authorAvatar,
        count: list.count,
        views: list.views,
        comments: list.comments,
        color: list.color,
        isPrivate: list.isPrivate,
        isFavorite: isFavorite,
        coverUrl: list.coverUrl,
        url: list.url,
        previewBooks: list.previewBooks,
      );

  /// Pull-to-refresh: revalidate page 1 in place when lists are on
  /// screen, otherwise do a full first load.
  Future<void> refresh() async {
    if (state.phase != BooklistsPhase.ready || state.lists.isEmpty) {
      return loadFirst();
    }
    if (!_alive) return;
    final generation = ++_generation;
    await _loadPage(
      1,
      replace: true,
      generation: generation,
      accountId: _accountIdFor(state.tab),
    );
  }

  Future<void> loadFirst() async {
    if (!_alive) return;
    // Only the own-lists tab needs a login; the discover tab is
    // public, so a signed-out user must still be able to browse it.
    if (state.tab == BooklistTab.mine &&
        ref.read(authProvider).user == null) {
      state = state.copyWith(
        phase: BooklistsPhase.loggedOut,
        lists: const [],
      );
      return;
    }
    final generation = ++_generation;
    final tab = state.tab;
    final accountId = _accountIdFor(tab);
    final url = _repository.booklistsPageUrl(
      mine: tab == BooklistTab.mine,
      query: state.query,
      order: state.order,
      page: 1,
    );
    final cachedPage = _repository.cachedListPage(url, accountId: accountId);
    if (cachedPage != null) {
      // Stale-while-revalidate: paint the last-known lists instantly,
      // then refresh page 1 in the background.
      _applyPage(cachedPage, 1, replace: true);
      unawaited(
        _loadPage(1, replace: true, generation: generation, accountId: accountId),
      );
      return;
    }
    // Same tab/query/order and lists already painted: this is a reload
    // of what the user is already looking at (provider rebuild, a
    // second load racing the first) — revalidate in the background
    // and never blank the painted lists. A tab/query/order change
    // still blanks: the painted lists belong to the old key.
    if (state.phase == BooklistsPhase.ready &&
        state.lists.isNotEmpty &&
        _paintedTab == state.tab &&
        _paintedQuery == state.query &&
        _paintedOrder == state.order) {
      unawaited(
        _loadPage(1, replace: true, generation: generation, accountId: accountId),
      );
      return;
    }
    state = state.copyWith(
      phase: BooklistsPhase.loading,
      lists: const [],
      nextPage: 1,
      hasMore: true,
      isLoadingMore: false,
      clearError: true,
    );
    await _loadPage(1, generation: generation, accountId: accountId);
  }

  Future<void> loadMore() async {
    final s = state;
    if (!_alive ||
        s.phase != BooklistsPhase.ready ||
        !s.hasMore ||
        s.isLoadingMore) {
      return;
    }
    await _loadPage(
      s.nextPage,
      generation: _generation,
      accountId: _accountIdFor(s.tab),
    );
  }

  Future<void> _loadPage(
    int page, {
    bool replace = false,
    required int generation,
    required String? accountId,
  }) async {
    final tab = state.tab;
    final query = state.query;
    final tracksLoadMore = page > 1;
    // This loadMore's identity: only the request currently holding
    // the flag may release it (see the finally below).
    final loadMoreToken = tracksLoadMore ? ++_loadMoreToken : 0;
    if (tracksLoadMore) {
      _loadMoreOwner = loadMoreToken;
      state = state.copyWith(isLoadingMore: true);
    }
    try {
      final response = tab == BooklistTab.mine
          ? await _repository.searchMyBooklists(
              query: query,
              order: state.order,
              page: page,
            )
          : await _repository.searchPublicBooklists(
              query: query,
              order: state.order,
              page: page,
            );
      if (!_isCurrent(generation)) return;
      final data = response.data;
      if (response.success && data != null) {
        _applyPage(data, page, replace: replace);
        return;
      }
      final error = response.error ?? 'Failed to load booklists';
      if (_repository.isChallengeError(response.error)) {
        await _loadViaSolver(
          page,
          error,
          replace: replace,
          generation: generation,
          accountId: accountId,
        );
        return;
      }
      _applyFailure(page, error, replace: replace);
    } catch (e) {
      if (!_isCurrent(generation)) return;
      _applyFailure(page, e.toString(), replace: replace);
    } finally {
      // A stale response (a refresh bumped the generation while this
      // loadMore was in flight) is dropped above WITHOUT any path that
      // resets isLoadingMore — the flag then blocks every future
      // loadMore() at the `s.isLoadingMore` guard forever. Reset it
      // here so pagination can never dead-lock. But only the request
      // currently holding the flag may release it: a newer loadMore
      // may have started since (a refresh cleared the way), and
      // clearing its flag would let a duplicate loadMore through.
      if (tracksLoadMore && _loadMoreOwner == loadMoreToken) {
        _loadMoreOwner = 0;
        state = state.copyWith(isLoadingMore: false);
      }
    }
  }

  /// Fetch one list page through the WebView solver and parse it. The
  /// own-lists page needs the login session. A failure reports the fast
  /// path's original error, so retry re-runs fast-then-solver.
  Future<void> _loadViaSolver(
    int page,
    String originalError, {
    required bool replace,
    required int generation,
    required String? accountId,
  }) async {
    final tab = state.tab;
    final url = _repository.booklistsPageUrl(
      mine: tab == BooklistTab.mine,
      query: state.query,
      order: state.order,
      page: page,
    );
    String? userId;
    String? userKey;
    if (tab == BooklistTab.mine) {
      final user = ref.read(authProvider).user;
      userKey = user?.remixUserkey;
      if (user == null || userKey == null || userKey.isEmpty) {
        // The session key is gone — show the login prompt.
        state = state.copyWith(phase: BooklistsPhase.loggedOut);
        return;
      }
      userId = user.id;
    }
    final html = await _repository.fetchViaSolver(
      url,
      accountId: accountId,
      userId: userId,
      userKey: userKey,
    );
    if (!_isCurrent(generation)) return;
    if (html == null) {
      _applyFailure(page, originalError, replace: replace);
      return;
    }
    _applyPage(
      _repository.parseListPage(html, baseUrl: Uri.parse(url).origin),
      page,
      replace: replace,
    );
  }

  void _applyPage(BooklistsPage data, int page, {bool replace = false}) {
    // The painted lists belong to this key from now on. Safe to read
    // from state here: a stale load (tab/query/order changed since it
    // started) is dropped before _applyPage is ever reached.
    _paintedTab = state.tab;
    _paintedQuery = state.query;
    _paintedOrder = state.order;
    state = state.copyWith(
      phase: BooklistsPhase.ready,
      // A background refresh replaces the cached page instead of
      // appending to it.
      lists: replace || page == 1 ? data.lists : [...state.lists, ...data.lists],
      // The site pages at 10 lists; a short page ends the list. A parsed
      // page count (0 = unknown) is the second signal.
      hasMore:
          data.lists.length >= _pageSize &&
          (data.totalPages <= 0 || page < data.totalPages),
      nextPage: page + 1,
      isLoadingMore: false,
      clearError: true,
    );
  }

  void _applyFailure(int page, String message, {bool replace = false}) {
    // A background refresh (cached lists on screen) never errors: the
    // cached data stays, and the next open or pull-to-refresh retries.
    // It still must clear a leftover loadMore flag — a loadMore that ran
    // concurrently with this refresh had its response dropped.
    if (replace) {
      state = state.copyWith(isLoadingMore: false);
      return;
    }
    if (page == 1) {
      state = state.copyWith(
        phase: BooklistsPhase.error,
        error: message,
        isLoadingMore: false,
      );
    } else {
      state = state.copyWith(isLoadingMore: false, hasMore: false);
    }
  }
}

final booklistsControllerProvider =
    NotifierProvider.autoDispose<BooklistsController, BooklistsState>(
      BooklistsController.new,
    );

// RecommendedBooklists*（发现页推荐书单）拆到了 recommended_booklists_provider.dart
