import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import '../../../utils/date_text.dart';
import 'comment_avatar.dart';
import 'comment_metric_chip.dart';

/// 单条评论。
///
/// 顶层评论渲染为浅色调卡片；回复（`parentId` 非空）缩进并带左侧线轨，
/// 与父评论视觉上成组（排序器保证回复紧跟父评论出现）。
class CommentCard extends StatelessWidget {
  final BookComment comment;
  final int replyCount;
  final bool likePending;
  final VoidCallback onLike;
  final VoidCallback onReply;
  final VoidCallback onAvatarTap;

  /// 自己的评论才可删（`comment.isCurrentUser`）；其余评论不显示。
  final bool canDelete;
  final VoidCallback onDelete;
  final String deleteTooltip;

  const CommentCard({
    super.key,
    required this.comment,
    required this.replyCount,
    required this.likePending,
    required this.onLike,
    required this.onReply,
    required this.onAvatarTap,
    required this.canDelete,
    required this.onDelete,
    required this.deleteTooltip,
  });

  @override
  Widget build(BuildContext context) {
    final isReply = comment.parentId != null;
    final body = _Body(
      comment: comment,
      replyCount: replyCount,
      likePending: likePending,
      onLike: onLike,
      onReply: onReply,
      onAvatarTap: onAvatarTap,
      canDelete: canDelete,
      onDelete: onDelete,
      deleteTooltip: deleteTooltip,
    );

    if (!isReply) {
      final cs = Theme.of(context).colorScheme;
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        child: body,
      );
    }
    // 回复：线轨起点对齐父评论头像中线，缩进一层。
    final railColor = Theme.of(context).colorScheme.outlineVariant;
    return Container(
      margin: const EdgeInsets.fromLTRB(48, 2, 16, 2),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: railColor, width: 2),
        ),
      ),
      child: body,
    );
  }
}

/// 卡片内部布局：头像 + (昵称/日期/正文/操作区)。
class _Body extends StatelessWidget {
  final BookComment comment;
  final int replyCount;
  final bool likePending;
  final VoidCallback onLike;
  final VoidCallback onReply;
  final VoidCallback onAvatarTap;
  final bool canDelete;
  final VoidCallback onDelete;
  final String deleteTooltip;

  const _Body({
    required this.comment,
    required this.replyCount,
    required this.likePending,
    required this.onLike,
    required this.onReply,
    required this.onAvatarTap,
    required this.canDelete,
    required this.onDelete,
    required this.deleteTooltip,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final date = commentDateText(comment.dateRelative, comment.date);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CommentAvatar(avatarUrl: comment.userAvatar, onTap: onAvatarTap),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      comment.userName,
                      style: tt.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (date.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.circle, size: 3, color: cs.outline),
                    ),
                    Flexible(
                      child: Text(
                        date,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (comment.text.isNotEmpty) ...[
                const SizedBox(height: 4),
                SelectableText(
                  comment.text,
                  style: tt.bodyMedium?.copyWith(height: 1.45),
                ),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  CommentMetricChip(
                    icon: Icons.chat_bubble_outline_rounded,
                    count: replyCount,
                    onTap: onReply,
                  ),
                  const SizedBox(width: 6),
                  CommentMetricChip(
                    icon: comment.isLiked
                        ? Icons.thumb_up_rounded
                        : Icons.thumb_up_outlined,
                    count: comment.likeCount,
                    active: comment.isLiked,
                    busy: likePending,
                    onTap: onLike,
                  ),
                  if (canDelete) ...[
                    const Spacer(),
                    IconButton(
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline_rounded),
                      iconSize: 20,
                      tooltip: deleteTooltip,
                      visualDensity: VisualDensity.compact,
                      color: cs.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
