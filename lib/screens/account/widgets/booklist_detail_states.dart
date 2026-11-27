import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/loading_widget.dart';

/// 书单详情页的空态与错误态 + 按需加载尾巴（原详情页的 `_body` /
/// `_loadMoreRow` / `_pageErrorRow`，P1-4 拆出；文案与行为不变）。
///
/// 每个 widget 都是一个 sliver（或直接放在 sliver 列表里的行），
/// 由详情页按状态选用。

/// 首屏加载中。
class BooklistDetailLoadingSliver extends StatelessWidget {
  const BooklistDetailLoadingSliver({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: 24),
        child: LoadingWidget(message: l10n.loading),
      ),
    );
  }
}

/// 首屏加载失败：错误文案 + 重试按钮。
class BooklistDetailErrorSliver extends StatelessWidget {
  final String? message;
  final VoidCallback onRetry;

  const BooklistDetailErrorSliver({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: EmptyState(
        icon: Icons.error_outline,
        title: l10n.error,
        message: message,
        action: FilledButton(
          onPressed: onRetry,
          child: Text(l10n.retry),
        ),
      ),
    );
  }
}

/// 空书单。
class BooklistDetailEmptySliver extends StatelessWidget {
  const BooklistDetailEmptySliver({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: EmptyState(
        icon: Icons.collections_bookmark_outlined,
        title: l10n.noBooklistBooks,
      ),
    );
  }
}

/// 客户端搜索过滤后无结果。
class BooklistDetailNoResultsSliver extends StatelessWidget {
  const BooklistDetailNoResultsSliver({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: EmptyState(
        icon: Icons.search_off_rounded,
        title: l10n.noBooksFound,
      ),
    );
  }
}

/// 按需加载的“加载更多”按钮：点一下拉一页。跟个人书单那边同款。
class BooklistDetailLoadMoreRow extends StatelessWidget {
  final VoidCallback onLoadMore;

  const BooklistDetailLoadMoreRow({super.key, required this.onLoadMore});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Center(
        child: TextButton(
          onPressed: onLoadMore,
          child: Text(l10n.loadMore),
        ),
      ),
    );
  }
}

/// 单页失败的重试行：已加载的书都留着，重试拉同一页（nextPage
/// 只在成功时才进位）。跟个人书单那边同款。
class BooklistDetailPageErrorRow extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const BooklistDetailPageErrorRow({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 20, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: onRetry,
            child: Text(l10n.retry),
          ),
        ],
      ),
    );
  }
}
