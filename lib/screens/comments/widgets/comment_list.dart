import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import '../../../widgets/loading_widget.dart';
import '../controllers/book_comments_controller.dart';
import 'comment_card.dart';

/// 评论列表：扁平渲染（回复紧跟父评论，排序器已保证线程相邻），
/// 顶层评论之间留大间距、回复紧贴父评论，视觉上自然成组。
///
/// 滚动监听与刷新逻辑在 screen 层；这里只负责画 [visibleCount] 条 + 尾部。
class CommentList extends StatelessWidget {
  final BookCommentsController controller;
  final ScrollController scrollController;

  /// 下拉刷新（screen 里转发 controller.loadFirst）。
  final Future<void> Function() onRefresh;

  /// 本地分页当前可见条数（controller.visibleCount）。
  final int visibleCount;

  /// “没有更多评论”文案；列表取尽后显示在底部。
  final String noMoreText;

  /// 回复按钮（screen 里联动输入框聚焦）。
  final ValueChanged<BookComment> onReply;

  /// 头像点击 → 用户主页。
  final ValueChanged<BookComment> onAvatarTap;

  /// 点赞切换（controller 内做乐观更新与回滚）。
  final ValueChanged<BookComment> onLike;

  /// 删除自己的评论（screen 里先弹确认框，再调 controller）。
  final ValueChanged<BookComment> onDelete;

  /// 删除按钮的 tooltip 文案（screen 里取本地化）。
  final String deleteTooltip;

  const CommentList({
    super.key,
    required this.controller,
    required this.scrollController,
    required this.onRefresh,
    required this.visibleCount,
    required this.noMoreText,
    required this.onReply,
    required this.onAvatarTap,
    required this.onLike,
    required this.onDelete,
    required this.deleteTooltip,
  });

  @override
  Widget build(BuildContext context) {
    final comments = controller.comments;
    final shown = visibleCount < comments.length
        ? visibleCount
        : comments.length;
    final hasMore = controller.hasMore;
    // 只有一屏取尽且确实加载过多页时才显示“没有更多”收尾。
    final showNoMore = !hasMore && comments.length > 1;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 12),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: shown + (hasMore ? 1 : 0) + (showNoMore ? 1 : 0),
        separatorBuilder: (context, index) {
          // 分隔线位于 index 与 index+1 之间：间距看“下一条”的类型——
          // 回复紧贴前一条（成组），下一条是顶层评论则拉开线程间距。
          if (index + 1 >= comments.length) return const SizedBox.shrink();
          return SizedBox(
            height: comments[index + 1].parentId == null ? 12 : 2,
          );
        },
        itemBuilder: (context, index) {
          if (index < shown) {
            final comment = comments[index];
            return CommentCard(
              comment: comment,
              replyCount: controller.replyCounts[comment.id] ?? 0,
              likePending: controller.likingIds.contains(comment.id),
              onLike: () => onLike(comment),
              onReply: () => onReply(comment),
              onAvatarTap: () => onAvatarTap(comment),
              canDelete: comment.isCurrentUser,
              onDelete: () => onDelete(comment),
              deleteTooltip: deleteTooltip,
            );
          }
          // 卡片之后的尾部：先分页加载指示器，再“没有更多”收尾。
          final tailIndex = index - shown;
          if (hasMore && tailIndex == 0) return const _ListFooter();
          return _NoMoreFooter(text: noMoreText);
        },
      ),
    );
  }
}

/// 本地分页的加载尾部。
class _ListFooter extends StatelessWidget {
  const _ListFooter();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 18),
      child: Center(child: LoadingWidget.more()),
    );
  }
}

/// 全部加载完的收尾提示。
class _NoMoreFooter extends StatelessWidget {
  final String text;

  const _NoMoreFooter({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: Row(
        children: [
          const Expanded(child: Divider(height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const Expanded(child: Divider(height: 1)),
        ],
      ),
    );
  }
}
