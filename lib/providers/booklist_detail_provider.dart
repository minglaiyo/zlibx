import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../services/booklist_repository.dart';
import 'auth_provider.dart';
import 'zlibrary_provider.dart';

/// Arguments for BooklistDetailScreen. Equality is by list id and
/// URL so the screen's provider family resolves to the same
/// controller on rebuild, while a list whose page moved (or whose
/// count changed) gets a fresh controller. `canEdit` is deliberately
/// excluded: the screen reads it from its own widget arguments, not
/// from the controller, so it must not force a new controller.
class BooklistDetailArgs {
  final Booklist booklist;

  /// True only when the signed-in user owns this list (opened from the
  /// mine tab of the booklists screen). Only then is removing a book
  /// offered; other users' lists are read-only here.
  final bool canEdit;

  const BooklistDetailArgs({required this.booklist, this.canEdit = false});

  @override
  bool operator ==(Object other) =>
      other is BooklistDetailArgs &&
      other.booklist.id == booklist.id &&
      other.booklist.url == booklist.url;

  @override
  int get hashCode => Object.hash(booklist.id, booklist.url);
}

class BooklistDetailState {
  /// True only while there is no local snapshot to paint yet.
  final bool isLoading;
  final bool isLoadingMore;
  final String? error;
  final List<Book> books;
  final bool hasMore;
  final int nextPage;

  const BooklistDetailState({
    this.isLoading = true,
    this.isLoadingMore = false,
    this.error,
    this.books = const [],
    this.hasMore = true,
    this.nextPage = 2,
  });

  BooklistDetailState copyWith({
    bool? isLoading,
    bool? isLoadingMore,
    String? error,
    bool clearError = false,
    List<Book>? books,
    bool? hasMore,
    int? nextPage,
  }) {
    return BooklistDetailState(
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: clearError ? null : (error ?? this.error),
      books: books ?? this.books,
      hasMore: hasMore ?? this.hasMore,
      nextPage: nextPage ?? this.nextPage,
    );
  }
}

/// Books inside one booklist. The last-known first page is painted from
/// a parsed Hive cache (or the list page preview as a cold-cache
/// fallback), then the detail page is always revalidated in the
/// background so changes made on the Z-Library website are picked up.
///
/// Page 1 comes from the detail page's own HTML (the site renders the
/// first page into the document; its JSON endpoint only serves page 2
/// and up, numeric id — asking it for page 1 answers "Requested page not
/// found"). Page 2+ comes from `getBooklistBooks`.
class BooklistDetailController
    extends AutoDisposeFamilyNotifier<BooklistDetailState, BooklistDetailArgs> {
  final List<Book> _books = [];
  // O(1) membership checks while pages are appended.
  final Set<int> _bookIds = <int>{};
  // IDs currently represented by the server-rendered first page. On a
  // revalidation, this slice is replaced while page 2+ rows are kept.
  final Set<int> _firstPageIds = <int>{};

  /// The three book structures are only ever mutated through the
  /// helpers below, so they cannot drift apart silently: [_bookIds]
  /// is exactly the id set of [_books], and [_firstPageIds] is the
  /// subset of [_bookIds] on the server-rendered first page.
  void _clearBooks() {
    _books.clear();
    _bookIds.clear();
    _firstPageIds.clear();
  }

  /// Adds [book] unless its id is already present. Returns true when
  /// the book was added.
  bool _addBook(Book book, {bool firstPage = false}) {
    if (!_bookIds.add(book.id)) return false;
    _books.add(book);
    if (firstPage) _firstPageIds.add(book.id);
    return true;
  }

  /// Inserts [book] at [index] unless its id is already present.
  /// Returns true when the book was inserted.
  bool _insertBook(Book book, int index, {bool firstPage = false}) {
    if (!_bookIds.add(book.id)) return false;
    _books.insert(index.clamp(0, _books.length), book);
    if (firstPage) _firstPageIds.add(book.id);
    return true;
  }

  /// Removes the book at [index] from all three structures and
  /// returns it.
  Book _removeBookAt(int index) {
    final removed = _books.removeAt(index);
    _bookIds.remove(removed.id);
    _firstPageIds.remove(removed.id);
    return removed;
  }

  /// Debug-only invariant check for tests: the id set matches the
  /// book list exactly, and the first-page ids are a subset of it.
  @visibleForTesting
  bool debugInvariantsHold() {
    if (_bookIds.length != _books.length) return false;
    for (final book in _books) {
      if (!_bookIds.contains(book.id)) return false;
    }
    return _bookIds.containsAll(_firstPageIds);
  }
  // Books with a remove in flight. The same book cannot be removed
  // twice concurrently; without this, two overlapping removes can
  // each resolve the entry id, then remove/restore the wrong row.
  final Set<int> _removingBookIds = <int>{};

  bool _alive = true;
  int _generation = 0;

  /// Data layer: fetching, parsing, the page cache and invalidation
  /// (see [BooklistRepository]). Holds no state of its own; rebuilt on
  /// every (re)build from the shared API instance.
  late BooklistRepository _repository;

  Booklist get _list => arg.booklist;

  String get _accountId => ref.read(authProvider).user?.id ?? 'signed-out';

  @override
  BooklistDetailState build(BooklistDetailArgs arg) {
    _repository = BooklistRepository(ref.read(zlibraryApiProvider));
    _alive = true;
    ref.onDispose(() => _alive = false);
    Future<void>.microtask(loadFirst);
    return const BooklistDetailState();
  }

  bool _isCurrent(int generation) => _alive && generation == _generation;

  Future<void> loadFirst() async {
    if (!_alive) return;
    final generation = ++_generation;
    // When this load's fetch started: a write that invalidates this
    // URL while the load is in flight must make the load's cache
    // stores drop (see BooklistHtmlCache), so the stale page cannot
    // re-enter the cache after the invalidation.
    final fetchedAt = DateTime.now();
    final list = _list;
    final preview = list.previewBooks;
    final accountId = _accountId;

    // Page 1 is cached independently of the booklist-list preview. The
    // preview belongs to the (possibly stale) list-page response and
    // must never prevent reading a newer detail-page cache.
    final cachedPage = _repository.cachedBooksPage(
      list.url,
      1,
      accountId: accountId,
    );
    final usableHtml = cachedPage == null
        ? _repository.cachedDetailHtml(list.url, accountId: accountId)
        : null;
    List<Book>? htmlBooks;
    if (usableHtml != null) {
      // Same guard as BooklistsController.loadFirst: the cache was written
      // by an older run — a parse failure must not escape loadFirst (which
      // runs from a microtask) and leave the screen loading forever.
      htmlBooks = _repository.parseCachedDetailBooks(
        usableHtml,
        baseUrl: Uri.parse(list.url).origin,
      );
    }
    final initialBooks = cachedPage ?? htmlBooks ?? preview;
    final hasLocalSnapshot =
        cachedPage != null || usableHtml != null || preview.isNotEmpty;

    _clearBooks();
    state = BooklistDetailState(isLoading: !hasLocalSnapshot);

    if (hasLocalSnapshot) {
      // Paint cached data immediately (including a cached empty list).
      // Even when the old count says there are no more books, always
      // revalidate: books may have been added on the website since.
      _applyFirstPage(initialBooks);
      state = state.copyWith(isLoadingMore: true);
      await _loadDetailPage(
        background: true,
        generation: generation,
        accountId: accountId,
        fetchedAt: fetchedAt,
      );
    } else {
      await _loadDetailPage(
        generation: generation,
        accountId: accountId,
        fetchedAt: fetchedAt,
      );
    }
    // The fetch predates a write that invalidated this URL mid-flight:
    // its data was dropped, and the snapshot it painted (if any) is
    // stale too — a refresh that started while a remove was still in
    // flight would otherwise leave the removed book on screen until
    // the next refresh. Retry once with a fresh fetch; a second
    // invalidation during the retry just drops again, no loop.
    if (_isCurrent(generation) &&
        _repository.wasInvalidatedAfter(
          list.url,
          fetchedAt,
          accountId: accountId,
        )) {
      await _loadDetailPage(
        background: hasLocalSnapshot,
        generation: generation,
        accountId: accountId,
        fetchedAt: DateTime.now(),
      );
    }
    if (!_isCurrent(generation)) return;
    state = state.copyWith(isLoading: false, isLoadingMore: false);
  }

  /// First page: the detail page's own HTML. Dio fast path first; on the
  /// browser-check wall, the WebView solver. In background mode a
  /// failure is silent — the cached/preview books stay on screen.
  Future<void> _loadDetailPage({
    bool background = false,
    required int generation,
    required String accountId,
    required DateTime fetchedAt,
  }) async {
    final list = _list;
    try {
      final response = await _repository.fetchDetailBooks(list);
      if (!_isCurrent(generation)) return;
      // A refresh that started while a remove was still in flight
      // carries the pre-remove page: its fetch predates the
      // invalidation, so applying it would resurrect the removed book
      // in the visible list even though the generation is current.
      if (_repository.wasInvalidatedAfter(
        list.url,
        fetchedAt,
        accountId: accountId,
      )) {
        return;
      }
      final data = response.data;
      if (response.success && data != null) {
        // Persist the parsed first page so the next visit paints
        // immediately without depending on the list-page preview.
        _repository.storeBooksPage(
          list.url,
          1,
          data,
          accountId: accountId,
          fetchedAt: fetchedAt,
        );
        _applyFirstPage(data);
        return;
      }
      final error = response.error ?? 'Failed to load booklist';
      if (_repository.isChallengeError(response.error)) {
        await _loadViaSolver(
          error,
          background: background,
          generation: generation,
          accountId: accountId,
          fetchedAt: fetchedAt,
        );
        return;
      }
      if (!background) _fail(error);
    } catch (e) {
      if (!_isCurrent(generation)) return;
      if (!background) _fail(e.toString());
    }
  }

  Future<void> _loadViaSolver(
    String originalError, {
    required bool background,
    required int generation,
    required String accountId,
    required DateTime fetchedAt,
  }) async {
    final url = _list.url;
    // An own list's page needs the session; a public page loads the same
    // either way.
    final user = ref.read(authProvider).user;
    final html = await _repository.fetchViaSolver(
      url,
      accountId: accountId,
      userId: user?.id,
      userKey: user?.remixUserkey,
    );
    if (!_isCurrent(generation)) return;
    // Same invalidation check as _loadDetailPage: the solver fetch
    // started with this load, so a write that completed meanwhile
    // makes its page stale.
    if (_repository.wasInvalidatedAfter(
      url,
      fetchedAt,
      accountId: accountId,
    )) {
      return;
    }
    if (html == null) {
      if (!background) _fail(originalError);
      return;
    }
    final books = _repository.parseDetailBooks(
      html,
      baseUrl: Uri.parse(url).origin,
    );
    _repository.storeBooksPage(
      url,
      1,
      books,
      accountId: accountId,
      fetchedAt: fetchedAt,
    );
    _applyFirstPage(books);
  }

  /// Load-more for JSON pages (2 and up). A cached page paints first
  /// (merged by id), then the network revalidates it; a failed refresh
  /// just ends the list with the cached rows still on screen.
  Future<void> loadMore() async {
    final s = state;
    if (!_alive ||
        s.isLoading ||
        s.isLoadingMore ||
        !s.hasMore ||
        s.error != null) {
      return;
    }
    final page = s.nextPage;
    final generation = _generation;
    // See loadFirst: when this load's fetch started, for the
    // invalidation check on its cache store.
    final fetchedAt = DateTime.now();
    final list = _list;
    final accountId = _accountId;
    final cachedPage = _repository.cachedBooksPage(
      list.url,
      page,
      accountId: accountId,
    );
    if (cachedPage != null) _merge(cachedPage);
    state = state.copyWith(isLoadingMore: true, books: List.of(_books));
    try {
      final response = await _repository.fetchBooksPage(list.id, page: page);
      if (!_isCurrent(generation)) return;
      // Same invalidation check as _loadDetailPage: a load-more that
      // started before a remove must not merge the removed book back.
      // Clear the flag on the way out: unlike the generation return
      // above (whose retirer is a newer load that clears the flags
      // when it completes), this retirement can come from a write on
      // another screen (add-to-booklist dialog), which has no
      // successor load to clear them — leaving them set would block
      // loadMore for the rest of this screen's lifetime.
      if (_repository.wasInvalidatedAfter(
        list.url,
        fetchedAt,
        accountId: accountId,
      )) {
        state = state.copyWith(isLoadingMore: false);
        return;
      }
      final data = response.data;
      if (response.success && data != null) {
        _repository.storeBooksPage(
          list.url,
          page,
          data.books,
          accountId: accountId,
          fetchedAt: fetchedAt,
        );
        // Merge by id: the cached page and the fresh page carry the
        // same books — adding both would duplicate the rows.
        _merge(data.books);
        state = state.copyWith(
          books: List.of(_books),
          hasMore: page < data.totalPages,
          nextPage: page + 1,
          isLoadingMore: false,
        );
      } else {
        // A failed later page must not silently end the list: a network
        // blip would look like "no more books" with no way back (and
        // setting `error` here would trip the loadMore guard above,
        // which blocks retries while an error is set). Keep hasMore so
        // the next scroll event re-enters loadMore and retries.
        state = state.copyWith(isLoadingMore: false);
      }
    } catch (e) {
      if (!_isCurrent(generation)) return;
      // Same as above: keep the list resumable instead of truncating it.
      state = state.copyWith(isLoadingMore: false);
    }
  }

  /// Remove one book from this list: optimistic removal; on failure
  /// the book is restored. On success every cached page of this list
  /// is invalidated so the book does not reappear from a later
  /// page's cache on the next open.
  ///
  /// remove-book takes the readlist ENTRY id (the per-(book, list)
  /// membership-row id), NOT the book id. The detail page's own cards
  /// carry it (`booklistsindex`, parsed into [Book.readlistBookId]),
  /// so it is used directly when present; otherwise it is resolved
  /// first via `current-user` and the remove call is only made with
  /// it. A null entry id (book not in this list) or a failed resolve
  /// fails here without calling remove-book at all: falling back to
  /// the book id is the bug that made the server 500 every app remove.
  ///
  /// Two removes of the same book cannot overlap (a
  /// [_removingBookIds] guard); removes of different books re-locate
  /// their target by id after each await, so a concurrent remove
  /// cannot shift one onto the wrong row. Restore inserts before
  /// the removed book's successor instead of a stale index.
  Future<ApiResponse<bool>> removeBook(Book book) async {
    if (!_alive) return ApiResponse.fail('remove book failed');
    final listId = int.tryParse(_list.id);
    if (listId == null) {
      return ApiResponse.fail('remove book not available');
    }
    if (_books.indexWhere((b) => b.id == book.id) < 0) {
      return ApiResponse.fail('book not in list');
    }
    if (!_removingBookIds.add(book.id)) {
      return ApiResponse.fail('book is already being removed');
    }
    try {
      final entry = book.readlistBookId != null
          ? ApiResponse.ok(book.readlistBookId)
          : await _resolveEntryId(book);
      if (!_alive) {
        return ApiResponse.fail('remove book failed');
      }
      final entryId = entry.data;
      if (!entry.success || entryId == null) {
        return ApiResponse.fail(
          entry.error ?? 'book is not in this booklist',
        );
      }
      // Re-locate by id: another remove may have shifted the list
      // while the entry id was being resolved.
      final currentIndex = _books.indexWhere((b) => b.id == book.id);
      if (currentIndex < 0) return ApiResponse.fail('book not in list');
      final wasFirstPage = _firstPageIds.contains(book.id);
      final successorId = currentIndex + 1 < _books.length
          ? _books[currentIndex + 1].id
          : null;
      final removed = _removeBookAt(currentIndex);
      // Retire in-flight loads NOW, not when the remove answers: a
      // load that started before this remove carries the book, and if
      // its response lands after the remove it would re-apply the
      // book to the visible list and re-store the stale page. Bumping
      // here makes the generation check drop it. The loading flags go
      // with the optimistic update — no load will complete them now,
      // so leaving them set would block loadMore for the rest of this
      // screen's lifetime.
      ++_generation;
      state = state.copyWith(
        books: List.of(_books),
        isLoading: false,
        isLoadingMore: false,
      );
      final response = await _repository.removeBookFromBooklist(
        booklistId: listId,
        readlistBookId: entryId,
      );
      if (response.success) {
        // Invalidate even when the controller is gone — the next
        // open must not paint the deleted book from a page cache.
        _repository.invalidateBooklist(
          _list.url,
          accountId: _accountId,
        );
      }
      if (!_alive) return response;
      if (response.success) return response;
      // Restore before the successor (or at the end when it is gone):
      // the captured index may be stale after a concurrent remove.
      // _insertBook skips the insert when the id is already present
      // (a concurrent loadMore may have re-added it), so the restore
      // can never duplicate a row.
      final restoreIndex = successorId == null
          ? _books.length
          : _books.indexWhere((b) => b.id == successorId);
      _insertBook(
        removed,
        restoreIndex < 0 ? _books.length : restoreIndex,
        firstPage: wasFirstPage,
      );
      state = state.copyWith(books: List.of(_books));
      return response;
    } finally {
      _removingBookIds.remove(book.id);
    }
  }

  /// Resolve one book's readlist ENTRY id via `current-user` (the
  /// fallback when the detail page's own card did not carry
  /// `booklistsindex`). Returns the repository response as-is: a
  /// failed lookup keeps its own error (the caller reports it), and
  /// only a successful lookup with null data means the book is not
  /// in this list. Collapsing a failure to null used to misreport a
  /// network failure as "book is not in this booklist".
  Future<ApiResponse<int?>> _resolveEntryId(Book book) async {
    final listId = int.tryParse(_list.id);
    if (listId == null) return ApiResponse.ok(null);
    try {
      return await _repository.resolveBookEntry(
        booklistId: listId,
        bookId: book.id,
      );
    } catch (_) {
      return ApiResponse.fail('resolve entry id failed');
    }
  }

  /// Save the per-book note on one of this (own) list's books: the
  /// entry id comes from the detail page's own card when present,
  /// else from the `current-user` lookup. On success the visible row
  /// is updated in place (an empty note clears the row's note) and
  /// the list's cached pages are invalidated so the note does not
  /// reappear from cache on the next open.
  Future<ApiResponse<bool>> saveNote(Book book, String note) async {
    if (!_alive) return ApiResponse.fail('save book note failed');
    final listId = int.tryParse(_list.id);
    if (listId == null) {
      return ApiResponse.fail('save book note not available');
    }
    final index = _books.indexWhere((b) => b.id == book.id);
    if (index < 0) {
      return ApiResponse.fail('book not in list');
    }
    try {
      final entry = book.readlistBookId != null
          ? ApiResponse.ok(book.readlistBookId)
          : await _resolveEntryId(book);
      if (!_alive) {
        return ApiResponse.fail('save book note failed');
      }
      final entryId = entry.data;
      if (!entry.success || entryId == null) {
        return ApiResponse.fail(
          entry.error ?? 'book is not in this booklist',
        );
      }
      final response = await _repository.saveBookDescription(
        listId: listId,
        entryId: entryId,
        description: note,
      );
      if (!response.success) return response;
      final trimmed = note.trim();
      _books[index] = _books[index].copyWith(
        note: trimmed.isEmpty ? '' : trimmed,
      );
      state = state.copyWith(books: List.of(_books));
      _repository.invalidateBooklist(_list.url, accountId: _accountId);
      return response;
    } catch (_) {
      return ApiResponse.fail('save book note failed');
    }
  }

  void _merge(List<Book> books) {
    for (final book in books) {
      _addBook(book);
    }
  }

  /// Replace stale first-page rows instead of only merging, so website-
  /// side additions/deletions propagate while page-2+ rows the user has
  /// already loaded are preserved.
  void _applyFirstPage(List<Book> books) {
    final laterPages = _books
        .where((book) => !_firstPageIds.contains(book.id))
        .toList();
    _clearBooks();
    for (final book in books) {
      _addBook(book, firstPage: true);
    }
    _merge(laterPages);
    state = state.copyWith(
      books: List.of(_books),
      // Do not trust the list page's book count here — it is stale
      // (the site's own count disagrees with the rendered cards).
      // A non-empty first page means page 2 may exist; the JSON
      // endpoint's totalPages arbitrates from page 2 on.
      hasMore: books.isNotEmpty,
      nextPage: 2,
    );
  }

  void _fail(String message) {
    state = state.copyWith(error: message, isLoading: false);
  }
}

final booklistDetailControllerProvider = NotifierProvider.autoDispose
    .family<BooklistDetailController, BooklistDetailState, BooklistDetailArgs>(
      BooklistDetailController.new,
    );
