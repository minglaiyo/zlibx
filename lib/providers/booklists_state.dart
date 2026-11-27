/// Booklists screen state model (P1-4 split of booklists_provider.dart):
/// the tab enum, the load phase and the immutable [BooklistsState].
/// The controller lives in booklists_controller.dart, cache invalidation
/// in booklists_cache.dart; booklists_provider.dart re-exports all three
/// so existing call sites keep importing it unchanged.
library;

import 'package:olib_api_plugin/olib_api_plugin.dart';

/// 书单页三个 tab,与官方站的三个入口一一对应:
/// `mine`=我的书集 /booklists/my、`discover`=公开专栏 /booklists、
/// `favorite`=最喜欢的书单 /booklists/favorite(2026-11-19 新增,
/// 长按收藏的他人书单落在这里)。
enum BooklistTab { mine, discover, favorite }

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
