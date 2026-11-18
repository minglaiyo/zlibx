import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../models/display_book.dart';
import '../../providers/author_books_provider.dart';
import '../../routes/app_routes.dart';
import '../../widgets/motion/motion.dart';
import '../../widgets/book_list_tile.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/loading_widget.dart';

/// 作者聚合页（方案 F2）：站点 `/author/{名}` 的分页书列表。进入即
/// 加载第一页，滚动到底自动 loadMore；列表项复用 BookListTile，点击
/// 进详情。空态给出"按作者搜索"的回退入口（站点聚合页偶尔与 eapi
/// 的作者串不一致）。
class AuthorScreen extends ConsumerStatefulWidget {
  const AuthorScreen({super.key, required this.author});

  /// 站点作者串（来自书籍详情页的 author 字段）。
  final String author;

  @override
  ConsumerState<AuthorScreen> createState() => _AuthorScreenState();
}

class _AuthorScreenState extends ConsumerState<AuthorScreen> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ref.read(authorBooksProvider(widget.author)).books.isEmpty &&
          !ref.read(authorBooksProvider(widget.author)).isLoading) {
        ref.read(authorBooksProvider(widget.author).notifier).load();
      }
    });
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 400) {
      ref.read(authorBooksProvider(widget.author).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(authorBooksProvider(widget.author));

    return Scaffold(
      appBar: AppBar(title: Text(widget.author, maxLines: 1)),
      body: _buildBody(context, l10n, state),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    AuthorBooksState state,
  ) {
    final cs = Theme.of(context).colorScheme;
    if (state.isLoading && state.books.isEmpty) {
      return LoadingWidget.page(message: l10n.loading);
    }
    if (state.error != null && state.books.isEmpty) {
      return EmptyState(
        icon: Icons.wifi_off_rounded,
        title: l10n.shelfSourceLoadFailed,
        message: l10n.shelfRetryHint,
        action: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.tonal(
              onPressed: () =>
                  ref.read(authorBooksProvider(widget.author).notifier).load(),
              child: Text(l10n.retry),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => AppRoutes.openSearchWithQuery(
                context,
                widget.author,
              ),
              child: Text(l10n.authorSearchFallback),
            ),
          ],
        ),
      );
    }
    if (state.books.isEmpty) {
      return EmptyState(
        icon: Icons.person_off_outlined,
        title: l10n.authorEmpty,
        message: l10n.shelfTryOtherFilter,
        action: TextButton(
          onPressed: () =>
              AppRoutes.openSearchWithQuery(context, widget.author),
          child: Text(l10n.authorSearchFallback),
        ),
      );
    }

    final rows = <Widget>[
      for (var i = 0; i < state.books.length; i++) ...[
        MotionEntrance(
          index: i,
          child: Builder(
            builder: (context) {
              final entry = state.books[i];
              final tile = BookListTile(
                book: entry.book.toDisplay(),
                showCover: true,
                onTap: () => AppRoutes.openBookDetailForDisplayBook(
                  context,
                  entry.book.toDisplay(),
                ),
              );
              // 下架书置灰并挡下载入口——与全文检索结果同一语义。
              return entry.removed
                  ? Opacity(opacity: 0.55, child: tile)
                  : tile;
            },
          ),
        ),
      ],
      if (state.isLoadingMore)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        )
      else if (state.hasMore)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: TextButton(
              onPressed: () => ref
                  .read(authorBooksProvider(widget.author).notifier)
                  .loadMore(),
              child: Text(l10n.loadMore),
            ),
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: Text(
              l10n.shelfCount(state.books.length),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
        ),
    ];

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: rows,
    );
  }
}
