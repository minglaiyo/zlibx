import 'package:flutter/material.dart';

/// 顶部书目上下文条：书籍图标 + 书名，右侧可选的评论数统计。
///
/// [commentCount] 为 null 时不显示统计（加载中/评论关闭/未登录等场景）。
class BookContextHeader extends StatelessWidget {
  final String title;
  final int? commentCount;

  const BookContextHeader({super.key, required this.title, this.commentCount});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.book_outlined,
              size: 19,
              color: cs.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: tt.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (commentCount != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: cs.secondaryContainer.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.forum_outlined,
                    size: 13,
                    color: cs.onSecondaryContainer,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatCount(commentCount!),
                    style: tt.labelSmall?.copyWith(
                      color: cs.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 1000 条以上缩写为 1.2k，避免长数字挤占书名空间。
  static String _formatCount(int count) {
    if (count >= 1000) {
      final k = count / 1000;
      final text = k >= 10 ? k.toStringAsFixed(0) : k.toStringAsFixed(1);
      return '${text}k';
    }
    return count.toString();
  }
}
