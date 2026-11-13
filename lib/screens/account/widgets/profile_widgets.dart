
import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../routes/app_routes.dart';
import '../../comments/widgets/comment_avatar.dart';
import '../../comments/widgets/comment_metric_chip.dart';
import '../comment_book_ref.dart';
import '../../../theme/app_metrics.dart';
import '../../../utils/date_text.dart';

/// 主页头部卡片：头像 + 昵称 + 统计药丸（评论数 / 书单数）。评论数
/// 来自评论接口，书单数来自书单区（加载中或无书单区时省略）。
/// 头像与昵称就是点进来的那条评论所见，无需再取。
class ProfileHeader extends StatelessWidget {
  final UserProfileArgs args;
  final int commentCount;
  final int? booklistCount;

  const ProfileHeader({
    super.key,
    required this.args,
    required this.commentCount,
    required this.booklistCount,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Material(
        color: cs.surfaceContainerLow,
        borderRadius: AppRadius.sheet,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CommentAvatar(avatarUrl: args.userAvatar, radius: 32),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Text(
                      args.userName,
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  ProfileStatPill(
                    icon: Icons.comment_outlined,
                    count: commentCount,
                  ),
                  if (booklistCount != null) ...[
                    const SizedBox(width: AppSpacing.sm),
                    ProfileStatPill(
                      icon: Icons.collections_bookmark_outlined,
                      count: booklistCount!,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 头部统计药丸：图标 + 数字（等宽数字，数字变化不跳动）。
class ProfileStatPill extends StatelessWidget {
  final IconData icon;
  final int count;

  const ProfileStatPill({super.key, required this.icon, required this.count});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: cs.onSecondaryContainer),
          const SizedBox(width: 5),
          // 数字变化时轻微上滑淡入（下拉刷新计数变化不跳变）。
          AnimatedSwitcher(
            duration: AppMotion.standard,
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.4),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: Text(
              '$count',
              key: ValueKey(count),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: cs.onSecondaryContainer,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡片化的一条主页评论，与“我的评论”页同一套视觉语言：
/// 书名行（封面缩略图 + 书名，点击 → 书籍详情）+ 头像/昵称/正文/
/// 日期与获赞数。点卡片其余区域进入该书的评论区；头像不可点——
/// 当前页就是这位用户的主页。
class ProfileCommentCard extends StatelessWidget {
  final UserCommentEntry entry;
  final String userName;

  /// 书名行的封面 URL；空串显示占位图（hash/封面未解析到）。
  final String coverUrl;

  /// 书 hash 解析中：书名行尾显示转圈并禁止再次点击。
  final bool isOpeningBook;
  final VoidCallback onCardTap;
  final VoidCallback onBookTap;

  const ProfileCommentCard({
    super.key,
    required this.entry,
    required this.userName,
    required this.coverUrl,
    required this.isOpeningBook,
    required this.onCardTap,
    required this.onBookTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final comment = entry.comment;
    final date = commentDateText(comment.dateRelative, comment.date);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: cs.surfaceContainerLow,
        borderRadius: AppRadius.sheet,
        child: InkWell(
          onTap: onCardTap,
          borderRadius: AppRadius.sheet,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 书名行 → 书籍详情（内层命中优先于卡片）。
                CommentBookTile(
                  title: entry.bookTitle,
                  coverUrl: coverUrl,
                  busy: isOpeningBook,
                  onTap: onBookTap,
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CommentAvatar(avatarUrl: comment.userAvatar),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            userName,
                            style: tt.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (comment.text.isNotEmpty) ...[
                            const SizedBox(height: AppSpacing.xs),
                            SelectableText(
                              comment.text,
                              style: tt.bodyMedium?.copyWith(height: 1.45),
                            ),
                          ],
                          const SizedBox(height: AppSpacing.sm + 2),
                          Row(
                            children: [
                              Text(
                                date,
                                style: tt.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              CommentMetricChip(
                                // 描边图标与评论区一致；纯展示获赞数，
                                // 不支持点赞切换。
                                icon: Icons.thumb_up_outlined,
                                count: comment.likeCount,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
