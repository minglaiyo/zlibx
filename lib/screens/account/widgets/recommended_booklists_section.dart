/// Recommended booklists above the discover list (P1-4 split of
/// booklists_screen.dart): a section header and a horizontal row of
/// grid tiles.
import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/booklist_detail_provider.dart';
import '../../routes/app_routes.dart';
import '../../widgets/booklist_quick_actions_sheet.dart';
import '../../widgets/booklist_tile.dart';
import '../../widgets/motion/entrance.dart';

/// Recommended booklists above the discover list: a section header and
/// a horizontal row of grid tiles.
class RecommendedBooklistsSection extends StatelessWidget {
  final AppLocalizations l10n;
  final List<Booklist> lists;

  const RecommendedBooklistsSection({required this.l10n, required this.lists});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            l10n.recommendedBooklists,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        _BooklistsCoverFlow(
          lists: lists,
          onOpen: (list) => AppRoutes.openBooklistDetail(
            context,
            BooklistDetailArgs(booklist: list),
          ),
          onLongPress: (list) => showBooklistQuickActionsSheet(context, list),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// 推荐区专用横向封面条(主体已改上下两列,见 BooklistMasonryGrid):
/// 158×224 大卡横向惯性滑动、错峰入场;不分页。
class _BooklistsCoverFlow extends StatelessWidget {
  final List<Booklist> lists;
  final ValueChanged<Booklist> onOpen;
  final ValueChanged<Booklist> onLongPress;

  const _BooklistsCoverFlow({
    required this.lists,
    required this.onOpen,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 252,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        itemCount: lists.length,
        itemBuilder: (context, index) {
          final list = lists[index];
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: MotionEntrance(
              index: index,
              child: BooklistCoverCard(
                list: list,
                width: 158,
                height: 224,
                onTap: () => onOpen(list),
                onLongPress: () => onLongPress(list),
              ),
            ),
          );
        },
      ),
    );
  }
}
