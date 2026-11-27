/// Typo tabs for the booklists screen (P1-4 split of
/// booklists_screen.dart): the selected tab is 22px bold with a short
/// ink bar, unselected tabs are small and grey; replaces the system
/// capsule segmented control (visual draft 1).
import 'package:flutter/material.dart';

import '../../providers/booklists_provider.dart';
import '../../theme/app_metrics.dart';

/// 排字式 tab:选中项 22px 加粗 + 短墨条(AnimatedContainer 展开),
/// 未选中回小字灰;取代系统胶囊分段器(视觉稿 ①)。
class BooklistsTypoTabs extends StatelessWidget {
  final BooklistTab active;
  final Map<BooklistTab, String> labels;
  final ValueChanged<BooklistTab> onSelect;

  const BooklistsTypoTabs({
    required this.active,
    required this.labels,
    required this.onSelect,
  });

  // 与书单屏的 _tabOrder 同序:我的 / 收藏 / 发现。
  static const _order = [
    BooklistTab.mine,
    BooklistTab.favorite,
    BooklistTab.discover,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 排字号 + 英文长标签可能超过屏宽:横向可滚,滚动条不显。
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _order.length; i++) ...[
            if (i > 0) const SizedBox(width: 18),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(_order[i]),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedDefaultTextStyle(
                    duration: AppMotion.fast,
                    style: _order[i] == active
                        ? theme.textTheme.titleLarge!.copyWith(
                            fontWeight: FontWeight.w800,
                          )
                        : theme.textTheme.bodyMedium!.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                    child: Text(labels[_order[i]]!),
                  ),
                  const SizedBox(height: 5),
                  AnimatedContainer(
                    duration: AppMotion.fast,
                    curve: Curves.easeOutCubic,
                    height: 3,
                    width: _order[i] == active ? 22 : 0,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(2),
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
}
