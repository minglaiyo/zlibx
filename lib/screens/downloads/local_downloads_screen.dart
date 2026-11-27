import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/download_provider.dart';
import '../../utils/app_snack.dart';
import '../../utils/file_utils.dart';
import 'widgets/completed_downloads_tab.dart';
import 'widgets/download_list.dart';
import 'widgets/downloads_app_bar.dart';


class LocalDownloadsScreen extends ConsumerStatefulWidget {
  const LocalDownloadsScreen({super.key});

  @override
  ConsumerState<LocalDownloadsScreen> createState() =>
      _LocalDownloadsScreenState();
}

class _LocalDownloadsScreenState extends ConsumerState<LocalDownloadsScreen> {
  /// 已完成列表的分类筛选：null = 全部；`kShelfUncategorizedId` =
  /// 未分类；其余 = 分类 id。分类树与书架共用一份（方案 C1）。
  String? _completedFilter;

  /// Open the downloads folder (Download/zlibx); failure shows a snack.
  Future<void> _openFolder() async {
    final l = AppLocalizations.of(context)!;
    try {
      final opened = await openDownloadFolder();
      if (!opened && context.mounted) {
        showAppSnack(context, l.openFolderFailed);
      }
    } catch (error) {
      if (context.mounted) {
        showAppSnack(context, l.openFolderFailed);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    // Structural watch only: the id lists (and so the tab counts and
    // order) change only when a task is added/removed, changes status,
    // or completes. Progress ticks do not rebuild this screen; each
    // row watches downloadTaskProvider for its own live task.
    final structure = ref.watch(downloadListStructureProvider);
    final ongoingIds = structure.ongoingIds;
    final completedIds = structure.completedIds;

    // No nested Scaffold: like the recommendation tab this page sits
    // under the home Scaffold (extendBody: true), so the lists can run
    // behind the floating nav. The header is a plain AppBar in a Column.
    final appBar = LocalDownloadsAppBar(
      title: l.downloads,
      openFolderTooltip: l.openFolder,
      ongoingLabel: '${l.ongoing} (${ongoingIds.length})',
      completedLabel: '${l.completed} (${completedIds.length})',
      accent: Theme.of(context).colorScheme.primary,
      onOpenFolder: _openFolder,
    );

    return DefaultTabController(
      length: 2,
      child: Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Column(
          children: [
            SizedBox(
              height:
                  appBar.preferredSize.height +
                  MediaQuery.paddingOf(context).top,
              child: appBar,
            ),
            Expanded(
              child: TabBarView(
                children: [
                  DownloadList(
                    taskIds: ongoingIds,
                    emptyIcon: Icons.downloading_rounded,
                    emptyTitle: l.noActiveDownloads,
                    emptyMessage: l.downloadsAppearHere,
                  ),
                  CompletedDownloadsTab(
                    taskIds: completedIds,
                    completedDates: structure.completedDates,
                    filter: _completedFilter,
                    onFilterChanged: (value) =>
                        setState(() => _completedFilter = value),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
