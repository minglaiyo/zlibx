// 发现页推荐书单（`POST /papi/booklist/get-from-category`）——从
// booklists_provider.dart 拆出（审查批可维护性发现 9）：与主书单控制
// 器无关，纯剪切迁移，API 不变。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../services/booklist_repository.dart';
import 'zlibrary_provider.dart';

/// Recommended booklists for the discover tab
/// (`POST /papi/booklist/get-from-category`). Loads once; a failure
/// leaves the section empty instead of erroring the screen, because
/// recommendations are an add-on above the paged list.
class RecommendedBooklistsState {
  final bool isLoading;
  final List<Booklist> lists;

  const RecommendedBooklistsState({
    this.isLoading = true,
    this.lists = const [],
  });

  RecommendedBooklistsState copyWith({
    bool? isLoading,
    List<Booklist>? lists,
  }) {
    return RecommendedBooklistsState(
      isLoading: isLoading ?? this.isLoading,
      lists: lists ?? this.lists,
    );
  }
}

class RecommendedBooklistsController
    extends AutoDisposeNotifier<RecommendedBooklistsState> {
  bool _alive = true;

  @override
  RecommendedBooklistsState build() {
    _alive = true;
    ref.onDispose(() => _alive = false);
    Future<void>.microtask(load);
    return const RecommendedBooklistsState();
  }

  Future<void> load() async {
    if (!_alive) return;
    final repository = BooklistRepository(ref.read(zlibraryApiProvider));
    try {
      final response = await repository.getRecommendedBooklists(
        booklistsCount: 10,
      );
      if (!_alive) return;
      state = state.copyWith(
        isLoading: false,
        lists: response.success ? (response.data ?? const []) : const [],
      );
    } catch (_) {
      if (!_alive) return;
      state = state.copyWith(isLoading: false, lists: const []);
    }
  }
}

final recommendedBooklistsProvider = NotifierProvider.autoDispose<
    RecommendedBooklistsController, RecommendedBooklistsState>(
  RecommendedBooklistsController.new,
);
