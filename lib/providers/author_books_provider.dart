import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../services/author_repository.dart';
import 'auth_provider.dart';
import 'zlibrary_provider.dart';


/// 作者聚合页（方案 F2）的分页状态。
class AuthorBooksState {
  const AuthorBooksState({
    this.books = const [],
    this.totalPages,
    this.currentPage = 0,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.error,
  });

  final List<CategoryBook> books;

  /// 页数来自页面自身的 `pagerOptions`；页面没带时为 null（用
  /// `hasMore` 的短页规则兜底）。
  final int? totalPages;
  final int currentPage;
  final bool isLoading;
  final bool isLoadingMore;
  final String? error;

  bool get hasMore =>
      error == null &&
      books.isNotEmpty &&
      (totalPages == null || currentPage < totalPages!);

  AuthorBooksState copyWith({
    List<CategoryBook>? books,
    int? totalPages,
    int? currentPage,
    bool? isLoading,
    bool? isLoadingMore,
    String? error,
    bool clearError = false,
  }) {
    return AuthorBooksState(
      books: books ?? this.books,
      totalPages: totalPages ?? this.totalPages,
      currentPage: currentPage ?? this.currentPage,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// 作者聚合页（方案 F2）：`/author/{名}` 的分页书列表。双通道（Dio
/// 直取，命中检查墙走 WebView solver）。屏幕 initState 调 [load]，
/// 滚动到底调 [loadMore]。
class AuthorBooksNotifier extends FamilyNotifier<AuthorBooksState, String> {
  @override
  AuthorBooksState build(String arg) => const AuthorBooksState();

  AuthorRepository get _repository =>
      AuthorRepository(ref.read(zlibraryApiProvider));

  int _requestId = 0;

  Future<void> load() async {
    final requestId = ++_requestId;
    state = const AuthorBooksState(isLoading: true);
    await _fetchPage(1, requestId);
  }

  Future<void> loadMore() async {
    final s = state;
    if (s.isLoading || s.isLoadingMore || !s.hasMore || s.error != null) {
      return;
    }
    final requestId = ++_requestId;
    state = s.copyWith(isLoadingMore: true);
    await _fetchPage(s.currentPage + 1, requestId);
  }

  Future<void> _fetchPage(int page, int requestId) async {
    final author = arg;
    final repo = _repository;
    try {
      final response = await repo.fetchBooks(author: author, page: page);
      if (requestId != _requestId) return;
      if (response.success && response.data != null) {
        _applyLoadedPage(response.data!, page, requestId, viaSolver: false);
        return;
      }
      if (repo.isChallengeError(response.error)) {
        await _fetchPageViaSolver(author, page, requestId);
        return;
      }
      state = state.copyWith(
        isLoading: false,
        isLoadingMore: false,
        error: response.error ?? 'author page failed',
      );
    } on Object catch (error) {
      if (requestId != _requestId) return;
      state = state.copyWith(
        isLoading: false,
        isLoadingMore: false,
        error: error.toString(),
      );
    }
  }

  Future<void> _fetchPageViaSolver(String author, int page, int requestId) async {
    final repo = _repository;
    final user = ref.read(authProvider).user;
    final html = await repo.fetchViaSolver(
      repo.authorPageUrl(author: author, page: page),
      userId: user?.id,
      userKey: user?.remixUserkey,
    );
    if (requestId != _requestId) return;
    CategoryPage? parsed;
    if (html != null) {
      parsed = await repo.parseBooks(html, baseUrl: Uri.parse(repo.authorPageUrl(author: author, page: page)).origin);
    }
    if (requestId != _requestId) return;
    if (parsed == null) {
      state = state.copyWith(
        isLoading: false,
        isLoadingMore: false,
        error: 'author page failed (solver)',
      );
      return;
    }
    _applyLoadedPage(parsed, page, requestId, viaSolver: true);
  }

  void _applyLoadedPage(
    CategoryPage data,
    int page,
    int requestId, {
    required bool viaSolver,
  }) {
    final s = state;
    final seen = {for (final b in s.books) b.book.id};
    final merged = List<CategoryBook>.of(s.books);
    for (final entry in data.books) {
      if (seen.add(entry.book.id)) merged.add(entry);
    }
    state = AuthorBooksState(
      books: merged,
      totalPages: data.totalPages,
      currentPage: page,
      isLoading: false,
      isLoadingMore: false,
    );
  }
}

final authorBooksProvider = NotifierProvider.family<AuthorBooksNotifier,
    AuthorBooksState, String>(AuthorBooksNotifier.new);
