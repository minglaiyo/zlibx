// Split out of `books_provider.dart` (M3): external search (Anna's Archive + LibGen) + their detail providers.
// `books_provider.dart` re-exports this file, so existing
// imports of `package:zlibx/providers/books_provider.dart` keep working.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/display_book.dart';
import '../services/annas_archieve.dart';
import '../services/external_search.dart';
import '../services/libgen_service.dart';
import '../services/network_error.dart';

// ── External Search (Anna's Archive + LibGen) ────────────────────────
//
// Mirrors SearchNotifier's shape, but over a swappable external provider
// (Anna's Archive or LibGen, chosen by the search screen). Neither has
// total_pages in its HTML search results, so pagination runs until an
// empty page comes back (hasMore = the last page returned books).

class ExternalSearchState {
  final List<DisplayBook> books;
  final int currentPage;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasSearched;
  final bool hasMore;
  final String? error;

  const ExternalSearchState({
    this.books = const [],
    this.currentPage = 0,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasSearched = false,
    this.hasMore = true,
    this.error,
  });

  ExternalSearchState copyWith({
    List<DisplayBook>? books,
    int? currentPage,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasSearched,
    bool? hasMore,
    String? error,
  }) {
    return ExternalSearchState(
      books: books ?? this.books,
      currentPage: currentPage ?? this.currentPage,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasSearched: hasSearched ?? this.hasSearched,
      hasMore: hasMore ?? this.hasMore,
      error: error,
    );
  }
}

class ExternalSearchNotifier extends Notifier<ExternalSearchState> {
  // Getters / mutable fields, not `late final`: see SearchNotifier above.
  AnnasArchieve get _annasApi => ref.read(annasArchieveProvider);
  late SearchProvider _provider;
  late BookSource _source;
  String? _lastQuery;
  int _requestId = 0;

  @override
  ExternalSearchState build() {
    _provider = AnnasArchiveProvider(api: _annasApi);
    _source = BookSource.annasArchive;
    return const ExternalSearchState();
  }

  SearchProvider _providerFor(BookSource source) => source == BookSource.libgen
      ? LibgenProvider()
      : AnnasArchiveProvider(api: _annasApi);

  /// Maps a provider's BookData with the converter matching the source
  /// that produced it (Anna and LibGen both return BookData).
  DisplayBook _toDisplay(BookData book) => _source == BookSource.libgen
      ? book.toLibgenDisplayBook()
      : book.toAnnaDisplayBook();

  Future<void> search(String query, BookSource source) async {
    final requestId = ++_requestId;
    _lastQuery = query;
    _source = source;
    _provider = _providerFor(source);
    state = const ExternalSearchState(isLoading: true, hasSearched: true);

    try {
      final books = await _provider.search(SearchQuery(text: query, page: 1));
      if (requestId != _requestId) return;
      state = ExternalSearchState(
        books: books.map<DisplayBook>(_toDisplay).toList(),
        currentPage: 1,
        hasSearched: true,
        hasMore: books.isNotEmpty,
      );
    } catch (e) {
      if (requestId != _requestId) return;
      state = ExternalSearchState(
        hasSearched: true,
        error: _errorMessage(e),
      );
    }
  }

  Future<void> loadMore() async {
    if (_lastQuery == null ||
        state.isLoadingMore ||
        !state.hasMore) {
      return;
    }

    final nextPage = state.currentPage + 1;
    final requestId = _requestId;
    state = state.copyWith(isLoadingMore: true);

    try {
      final books = await _provider.search(
        SearchQuery(text: _lastQuery!, page: nextPage),
      );
      if (requestId != _requestId) return;
      state = state.copyWith(
        books: [
          ...state.books,
          ...books.map<DisplayBook>(_toDisplay),
        ],
        currentPage: nextPage,
        isLoadingMore: false,
        hasMore: books.isNotEmpty,
      );
    } catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(
        isLoadingMore: false,
        error: _errorMessage(e),
      );
    }
  }

  void reset() {
    _requestId++;
    _lastQuery = null;
    state = const ExternalSearchState();
  }

  /// NetworkError carries a human-readable userMessage (its toString is
  /// just `NetworkError.<type>`); surface that, fall back to toString.
  static String _errorMessage(Object e) {
    if (e is NetworkError) return e.userMessage;
    return e.toString();
  }
}

final externalSearchProvider =
    NotifierProvider<ExternalSearchNotifier, ExternalSearchState>(
      ExternalSearchNotifier.new,
    );

/// Shared [AnnasArchieve] instance: its Dio (and connection pool) is
/// reused across detail and search requests instead of being rebuilt
/// per call. The service holds no per-request mutable state (its headers
/// map is only read), so sharing one instance is safe.
final annasArchieveProvider =
    Provider<AnnasArchieve>((ref) => AnnasArchieve());

// ── Anna's Archive Book Details ──────────────────────────────────────
//
// [link] is the BookData.link from a search result (relative "/md5/…"
// URL). AnnasArchieve.bookInfo throws on failure (Cloudflare block, no
// mirror, parse failure), so the provider surfaces the error as-is.
/// autoDispose：详情页关掉后无人 watch 即释放缓存；每条 link 各占一
/// 个缓存项，重度浏览否则无界增长。
final annasBookDetailsProvider =
    FutureProvider.autoDispose.family<BookInfoData, String>((ref, link) async {
      final archive = ref.watch(annasArchieveProvider);
      return archive.bookInfo(url: link);
    });

/// Shared LibGen service instance. Creating one per detail request built
/// a fresh Dio (and a fresh keep-alive HttpClient pool) every time the
/// user opened a LibGen book — the same leak pattern the search side
/// already fixed with [annasArchieveProvider].
final libgenServiceProvider =
    Provider<LibgenService>((ref) => LibgenService());

// ── LibGen Book Details ──────────────────────────────────────────────
//
// [link] is the BookData.link from a search result (an absolute
// "ads.php?md5=…" URL). LibgenService.bookInfo returns null on failure
// (no mirror, non-200, parse failure), so the provider turns that into
// a StateError for the detail page's error UI.
/// autoDispose：与 [annasBookDetailsProvider] 同理，详情页关掉即释放。
final libgenBookDetailsProvider =
    FutureProvider.autoDispose.family<BookInfoData, String>((ref, link) async {
      final info = await ref.watch(libgenServiceProvider).bookInfo(link);
      if (info == null) throw StateError('Failed to load book details');
      return info;
    });
