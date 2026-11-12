import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../models/display_book.dart';
import '../services/home_feed_cache.dart';
import 'zlibrary_provider.dart';

/// Home feed state: a never-ending list of books.
///
/// The feed is seeded with the personalised recommendations and then keeps
/// appending popular pages. When an ordering runs out of pages it rolls over
/// to the next ordering (popular -> newest uploads -> publish year), which is
/// what makes the grid scroll indefinitely instead of stopping at the 20
/// books the recommendations endpoint returns.
class HomeFeedState {
  const HomeFeedState({
    this.books = const <DisplayBook>[],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.error,
    this.loadMoreError,
    this.refreshedAt,
    this.page = 1,
    this.orderIndex = 0,
  });

  final List<DisplayBook> books;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final Object? error;
  final Object? loadMoreError;

  /// When the feed last received content (used by the auto-refresh policy).
  final DateTime? refreshedAt;

  /// Next page to request for [orderIndex].
  final int page;
  final int orderIndex;

  bool isStale(Duration maxAge) {
    final last = refreshedAt;
    return last == null || DateTime.now().difference(last) >= maxAge;
  }

  HomeFeedState copyWith({
    List<DisplayBook>? books,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    Object? error = _notProvided,
    Object? loadMoreError = _notProvided,
    DateTime? refreshedAt,
    int? page,
    int? orderIndex,
  }) {
    return HomeFeedState(
      books: books ?? this.books,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: identical(error, _notProvided) ? this.error : error,
      loadMoreError: identical(loadMoreError, _notProvided)
          ? this.loadMoreError
          : loadMoreError,
      refreshedAt: refreshedAt ?? this.refreshedAt,
      page: page ?? this.page,
      orderIndex: orderIndex ?? this.orderIndex,
    );
  }
}

const Object _notProvided = Object();

class HomeFeedNotifier extends Notifier<HomeFeedState> {
  static const int pageSize = 24;

  /// Orderings are consumed in this order; each one is paged until its
  /// total_pages meta value is reached.
  static const List<String> _orders = <String>['popular', 'date', 'year'];

  /// How many empty/duplicate pages to consume inside a single load call
  /// before giving up and letting the user scroll again.
  static const int _maxPagesPerLoad = 3;

  final Set<String> _seen = <String>{};
  int _generation = 0;
  bool _loadInFlight = false;
  bool _disposed = false;

  ZLibraryApi get _api => ref.read(zlibraryApiProvider);

  @override
  HomeFeedState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    final generation = ++_generation;
    _seen.clear();
    _loadInFlight = false;

    // Warm start: show the last feed immediately, then let the home tab's
    // existing staleness policy decide whether to refresh. The skeleton is
    // only shown on a true first launch (or after the cache was cleared).
    final cached = HomeFeedCache.read();
    if (cached != null) {
      for (final book in cached.books) {
        _seen.add(book.id);
      }
      return HomeFeedState(
        books: cached.books,
        refreshedAt: cached.savedAt,
        page: cached.page,
        orderIndex: cached.orderIndex,
      );
    }

    unawaited(_bootstrap(generation));
    return const HomeFeedState(isLoading: true);
  }

  void _saveCache() {
    final snapshot = state;
    if (snapshot.books.isEmpty) return;
    unawaited(
      HomeFeedCache.save(
        books: snapshot.books,
        savedAt: snapshot.refreshedAt ?? DateTime.now(),
        page: snapshot.page,
        orderIndex: snapshot.orderIndex,
      ),
    );
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  Future<void> _bootstrap(int generation) async {
    try {
      final response = await _api.getUserRecommended();
      if (!_isCurrent(generation)) return;
      if (!response.success) {
        throw StateError(response.error ?? 'Failed to load recommendations');
      }
      final books = _collect(response.data ?? const <Book>[]);
      state = HomeFeedState(
        books: List<DisplayBook>.unmodifiable(books),
        refreshedAt: DateTime.now(),
        page: 1,
        orderIndex: 0,
      );
      _saveCache();
      // Do not stop at the 20-odd recommendation rows: top the first screen
      // up with the first popular page in the background.
      unawaited(loadMore());
    } catch (error) {
      if (!_isCurrent(generation)) return;
      state = HomeFeedState(error: error, refreshedAt: DateTime.now());
    }
  }

  /// Manual retry after the initial load failed.
  Future<void> retryInitial() async {
    final generation = ++_generation;
    _seen.clear();
    _loadInFlight = false;
    state = const HomeFeedState(isLoading: true);
    await _bootstrap(generation);
  }

  /// Appends the next page. Safe to call from a scroll listener: duplicate
  /// calls while a request is running are ignored.
  Future<void> loadMore() async {
    if (_loadInFlight || state.isLoading || state.isLoadingMore) return;
    if (!state.hasMore) return;

    final generation = _generation;
    _loadInFlight = true;
    state = state.copyWith(isLoadingMore: true, loadMoreError: null);

    var order = state.orderIndex;
    var page = state.page;
    var fresh = const <DisplayBook>[];
    var cycleComplete = false;
    Object? error;

    try {
      for (var attempt = 0; attempt < _maxPagesPerLoad; attempt++) {
        final response = await _api.search(
          order: _orders[order],
          page: page,
          limit: pageSize,
        );
        if (!_isCurrent(generation)) return;
        if (!response.success) {
          error = StateError(response.error ?? 'Failed to load more books');
          break;
        }
        final batch = response.data ?? const <Book>[];
        fresh = _collect(batch);
        final advanced = _advance(
          order: order,
          page: page,
          batchLength: batch.length,
          totalPages: _intOf(response.meta?['total_pages']),
        );
        order = advanced.order;
        page = advanced.page;
        cycleComplete = advanced.cycleComplete;
        if (fresh.isNotEmpty || cycleComplete) break;
      }
    } catch (e) {
      error = e;
    } finally {
      _loadInFlight = false;
    }

    if (!_isCurrent(generation)) return;

    state = state.copyWith(
      books: fresh.isEmpty
          ? state.books
          : List<DisplayBook>.unmodifiable(<DisplayBook>[
              ...state.books,
              ...fresh,
            ]),
      isLoadingMore: false,
      orderIndex: order,
      page: page,
      hasMore: !(cycleComplete && fresh.isEmpty),
      loadMoreError: error,
      error: error == null ? null : state.error,
      refreshedAt: fresh.isEmpty ? null : DateTime.now(),
    );
    if (fresh.isNotEmpty) _saveCache();
  }

  /// Pull-to-refresh: fetch the next unseen page and put it on top, so the
  /// user actually gets new books without losing the pages already loaded.
  /// Returns how many new books were prepended.
  Future<int> refresh() async {
    if (state.isLoading || _loadInFlight) return 0;

    final generation = _generation;
    final order = state.orderIndex;
    final page = state.page;
    _loadInFlight = true;
    try {
      final response = await _api.search(
        order: _orders[order],
        page: page,
        limit: pageSize,
      );
      if (!_isCurrent(generation)) return 0;
      if (!response.success) {
        throw StateError(response.error ?? 'Failed to refresh');
      }
      final batch = response.data ?? const <Book>[];
      final fresh = _collect(batch);
      final advanced = _advance(
        order: order,
        page: page,
        batchLength: batch.length,
        totalPages: _intOf(response.meta?['total_pages']),
      );
      state = state.copyWith(
        books: fresh.isEmpty
            ? state.books
            : List<DisplayBook>.unmodifiable(<DisplayBook>[
                ...fresh,
                ...state.books,
              ]),
        page: advanced.page,
        orderIndex: advanced.order,
        hasMore: fresh.isNotEmpty ? true : state.hasMore,
        refreshedAt: DateTime.now(),
        loadMoreError: null,
        error: null,
      );
      if (fresh.isNotEmpty) _saveCache();
      return fresh.length;
    } finally {
      _loadInFlight = false;
    }
  }

  /// Called when the app returns to the foreground or the home tab becomes
  /// visible again. Refreshes only when the feed has gone stale.
  ///
  /// At the top we prepend fresh books (visible immediately); deeper in the
  /// list we append instead, so the viewport never jumps under the finger.
  Future<void> autoRefresh({required bool atTop}) async {
    if (state.isLoading || _loadInFlight) return;
    if (!state.isStale(const Duration(minutes: 15))) return;
    try {
      if (atTop) {
        await refresh();
      } else {
        await loadMore();
        if (_isCurrent(_generation)) {
          state = state.copyWith(refreshedAt: DateTime.now());
        }
      }
    } catch (_) {
      // Auto refresh is best-effort: never interrupt reading with a snackbar.
    }
  }

  /// Turns a batch of API books into unique display books, remembering every
  /// id ever shown so pages that overlap never produce duplicate cards (and
  /// therefore never duplicate Hero tags or grid keys).
  List<DisplayBook> _collect(Iterable<Book> books) {
    final out = <DisplayBook>[];
    for (final book in books) {
      final display = book.toDisplay();
      if (display.id.isEmpty) continue;
      if (_seen.add(display.id)) out.add(display);
    }
    return out;
  }

  ({int order, int page, bool cycleComplete}) _advance({
    required int order,
    required int page,
    required int batchLength,
    required int? totalPages,
  }) {
    final lastPage =
        batchLength == 0 || (totalPages != null && page >= totalPages);
    if (!lastPage) {
      return (order: order, page: page + 1, cycleComplete: false);
    }
    final nextOrder = order + 1;
    if (nextOrder < _orders.length) {
      return (order: nextOrder, page: 1, cycleComplete: false);
    }
    return (order: 0, page: 1, cycleComplete: true);
  }

  static int? _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}

final homeFeedProvider = NotifierProvider<HomeFeedNotifier, HomeFeedState>(
  HomeFeedNotifier.new,
);
