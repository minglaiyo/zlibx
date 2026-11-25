import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../models/display_book.dart';
import '../../providers/download_provider.dart';
import '../../providers/shelf_categories_provider.dart';
import '../../screens/favorites/category_actions.dart';
import '../../screens/favorites/widgets/shelf_chip.dart';
import '../../screens/reader/local_reader_screen.dart';
import '../../services/media_store.dart';
import '../../services/reader_formats.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_snack.dart';
import '../../utils/cover_cache.dart';
import '../../utils/date_text.dart';
import '../../utils/error_text.dart';
import '../../utils/file_utils.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/motion/motion.dart';


class LocalDownloadsScreen extends ConsumerStatefulWidget {
  const LocalDownloadsScreen({super.key});

  @override
  ConsumerState<LocalDownloadsScreen> createState() =>
      _LocalDownloadsScreenState();
}

class _LocalDownloadsScreenState extends ConsumerState<LocalDownloadsScreen> {
  /// 已完成列表的分类筛选：null = 全部；[kShelfUncategorizedId] =
  /// 未分类；其余 = 分类 id。分类树与书架共用一份（方案 C1）。
  String? _completedFilter;

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
    final appBar = AppBar(
      title: Text(l.downloads),
      actions: [
        IconButton(
          tooltip: l.openFolder,
          icon: const Icon(Icons.folder_open_rounded),
          onPressed: () async {
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
          },
        ),
      ],
      bottom: TabBar(
        indicatorColor: Theme.of(context).colorScheme.primary,
        labelColor: Theme.of(context).colorScheme.primary,
        tabs: [
          Tab(text: '${l.ongoing} (${ongoingIds.length})'),
          Tab(text: '${l.completed} (${completedIds.length})'),
        ],
      ),
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
                  _DownloadList(
                    taskIds: ongoingIds,
                    emptyIcon: Icons.downloading_rounded,
                    emptyTitle: l.noActiveDownloads,
                    emptyMessage: l.downloadsAppearHere,
                  ),
                  _CompletedTab(
                    taskIds: completedIds,
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

/// 已完成 Tab：分类筛选条 + 书架网格。任务 id 就是 bookId（历史条目按
/// bookId 存），分类归属用 `download:<bookId>` 键写进书架分类的
/// assignments 表。点一本书进 in-app 阅读器（foliate，见
/// local_reader_screen.dart）；PDF 等阅读器打不开的格式走外部打开。
class _CompletedTab extends ConsumerWidget {
  const _CompletedTab({
    required this.taskIds,
    required this.filter,
    required this.onFilterChanged,
  });

  final List<String> taskIds;
  final String? filter;
  final ValueChanged<String?> onFilterChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context)!;
    final categories = ref.watch(shelfCategoriesProvider);
    final visible = taskIds.where((id) {
      final assigned = categories.assignments['download:$id'];
      if (filter == kShelfUncategorizedId) return assigned == null;
      if (filter != null) return assigned == filter;
      return true;
    }).toList();

    return Column(
      children: [
        _CompletedCategoryBar(
          taskIds: taskIds,
          selected: filter,
          onSelected: onFilterChanged,
        ),
        Expanded(
          child: _CompletedBookshelf(
            taskIds: visible,
            emptyIcon: filter == null
                ? Icons.check_circle_outline_rounded
                : Icons.search_off_rounded,
            emptyTitle: filter == null
                ? l.noCompletedDownloads
                : l.shelfNoMatches,
            emptyMessage: filter == null
                ? l.downloadedBooksHere
                : l.shelfTryOtherFilter,
          ),
        ),
      ],
    );
  }
}

/// 已完成书架：封面网格，点书进阅读器。顺序就是 completedIds 的顺序
/// （最新下载在前）。分类筛选在上层 [_CompletedTab] 里做。
class _CompletedBookshelf extends StatelessWidget {
  const _CompletedBookshelf({
    required this.taskIds,
    required this.emptyIcon,
    required this.emptyTitle,
    required this.emptyMessage,
  });

  final List<String> taskIds;
  final IconData emptyIcon;
  final String emptyTitle;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (taskIds.isEmpty) {
      return EmptyState(
        icon: emptyIcon,
        title: emptyTitle,
        message: emptyMessage,
      );
    }
    // Bottom 124 = 28 gap + 96 floating-nav clearance, reserved
    // inside the grid so items scroll behind the pill (like the
    // home grid).
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 124),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 120,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: 0.55,
      ),
      itemCount: taskIds.length,
      itemBuilder: (context, index) => MotionEntrance(
        index: index,
        child: _BookshelfCard(id: taskIds[index]),
      ),
    );
  }
}

/// 书架上的一本书：封面 + 书名 + 作者·格式。点卡片进阅读器（PDF
/// 等打不开的格式走外部打开）；右上角小菜单保留原有的归类 / 详情 /
/// 分享 / 删除。
class _BookshelfCard extends ConsumerWidget {
  const _BookshelfCard({required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(downloadTaskProvider(id));
    if (task == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final meta = [
      if (task.book.author?.isNotEmpty == true) task.book.author!,
      if (task.book.extension?.isNotEmpty ?? false)
        task.book.extension!.toUpperCase(),
    ].join(' · ');

    return InkWell(
      onTap: () => _openBook(context, ref, task),
      borderRadius: BorderRadius.circular(9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: SizedBox.expand(
                    child: task.book.cover?.isNotEmpty == true
                        ? CachedNetworkImage(
                            imageUrl: task.book.cover!,
                            fit: BoxFit.cover,
                            memCacheWidth: coverCacheWidth(120, context),
                            memCacheHeight: coverCacheHeight(160, context),
                            errorWidget: (_, __, ___) =>
                                _coverPlaceholder(cs, task.book.title),
                          )
                        : _coverPlaceholder(cs, task.book.title),
                  ),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: _CardMenuButton(task: task),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            task.book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme cs, String title) => ColoredBox(
    color: cs.surfaceContainerHighest,
    child: Center(
      child: Text(
        title.isNotEmpty ? title[0] : '?',
        style: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          color: cs.onSurfaceVariant,
        ),
      ),
    ),
  );

  Future<void> _openBook(
    BuildContext context,
    WidgetRef ref,
    DownloadTask task,
  ) async {
    // 阅读器能开的格式进 in-app 阅读器；PDF 等进外部打开。
    if (isReadableExtension(task.book.extension)) {
      // openLocalReaderForTask 返回 false = 文件没了（已弹提示并
      // 标记），不用再外部打开。
      await openLocalReaderForTask(context, ref, task);
      return;
    }
    await openDownloadedFileExternally(context, ref, task);
  }
}

/// 书架卡片右上角的小菜单：归类 / 文件详情 / 分享 / 删除（与列表
/// 行的菜单同一套处理，见 [handleDownloadMenuAction]）。
class _CardMenuButton extends ConsumerWidget {
  const _CardMenuButton({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SizedBox(
        width: 26,
        height: 26,
        child: PopupMenuButton<String>(
          tooltip: l.more,
          padding: EdgeInsets.zero,
          iconSize: 18,
          onSelected: (value) =>
              handleDownloadMenuAction(context, ref, task, value),
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'category',
              child: Text(l.shelfAddToCategory),
            ),
            PopupMenuItem(value: 'details', child: Text(l.fileDetails)),
            PopupMenuItem(value: 'share', child: Text(l.share)),
            const PopupMenuDivider(),
            PopupMenuItem(value: 'delete', child: Text(l.downloadDeleteFile)),
          ],
          icon: const Icon(Icons.more_horiz_rounded),
        ),
      ),
    );
  }
}

/// 分类筛选 chips：全部 / 未分类 / 各分类 + 计数。分类的新建与改名
/// 仍在书架的「管理分类」里，这里只消费同一棵树。
class _CompletedCategoryBar extends ConsumerWidget {
  const _CompletedCategoryBar({
    required this.taskIds,
    required this.selected,
    required this.onSelected,
  });

  final List<String> taskIds;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context)!;
    final categories = ref.watch(shelfCategoriesProvider);
    String? assignedFor(String id) => categories.assignments['download:$id'];

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Center(
              child: ShelfChip(
                label: '${l.shelfAllCategories} ${taskIds.length}',
                selected: selected == null,
                dense: true,
                onSelected: () => onSelected(null),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Center(
              child: ShelfChip(
                label:
                    '${l.shelfUncategorized} '
                    '${taskIds.where((id) => assignedFor(id) == null).length}',
                selected: selected == kShelfUncategorizedId,
                dense: true,
                onSelected: () => onSelected(kShelfUncategorizedId),
              ),
            ),
          ),
          for (final category in categories.categories)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Center(
                child: ShelfChip(
                  label:
                      '${category.name} '
                      '${taskIds.where((id) => assignedFor(id) == category.id).length}',
                  selected: selected == category.id,
                  dense: true,
                  onSelected: () => onSelected(category.id),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DownloadList extends StatelessWidget {
  const _DownloadList({
    required this.taskIds,
    required this.emptyIcon,
    required this.emptyTitle,
    required this.emptyMessage,
  });

  final List<String> taskIds;
  final IconData emptyIcon;
  final String emptyTitle;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (taskIds.isEmpty) {
      return EmptyState(
        icon: emptyIcon,
        title: emptyTitle,
        message: emptyMessage,
      );
    }
    // Bottom 124 = 28 gap + 96 floating-nav clearance, reserved
    // inside the list so items scroll behind the pill (like the
    // home grid).
    const padding = EdgeInsets.fromLTRB(16, 16, 16, 124);
    return ListView.separated(
      padding: padding,
      itemCount: taskIds.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, index) => MotionEntrance(
        index: index,
        child: _DownloadItem(id: taskIds[index]),
      ),
    );
  }
}

class _DownloadItem extends ConsumerWidget {
  const _DownloadItem({required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Per-task watch: only this task's changes rebuild this row.
    // A null task means the record was removed after the list was
    // built; render nothing rather than a stale snapshot.
    final task = ref.watch(downloadTaskProvider(id));
    if (task == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isActive =
        task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.pending;
    final isComplete = task.status == DownloadStatus.completed;
    final source = task.source;
    final details = [
      // #143：来源标最前面（z站 / Anna's Archive / LibGen）。没存
      // 来源的旧记录不标。
      if (source != null)
        switch (source) {
          BookSource.zlibrary => l.sourceZlibrary,
          BookSource.annasArchive => l.sourceAnnasArchive,
          BookSource.libgen => l.sourceLibgen,
        },
      if (task.book.extension?.isNotEmpty ?? false)
        task.book.extension!.toUpperCase(),
      if (task.fileSize != null) _formatSize(task.fileSize!),
      if (task.fileSize == null &&
          (task.book.filesizeString?.isNotEmpty ?? false))
        task.book.filesizeString!,
      if (task.downloadedAt != null) formatDownloadDate(task.downloadedAt!),
    ].join(' · ');

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: SizedBox(
                    width: 64,
                    height: 92,
                    child: task.book.cover?.isNotEmpty == true
                        ? CachedNetworkImage(
                            imageUrl: task.book.cover!,
                            fit: BoxFit.cover,
                            memCacheWidth: coverCacheWidth(64, context),
                            memCacheHeight: coverCacheHeight(92, context),
                            errorWidget: (_, __, ___) => _coverPlaceholder(cs),
                          )
                        : _coverPlaceholder(cs),
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        task.book.author?.isNotEmpty == true
                            ? task.book.author!
                            : l.unknownAuthor,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (details.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        Text(
                          details,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                      const SizedBox(height: 9),
                      _statusLabel(context, l, task),
                    ],
                  ),
                ),
              ],
            ),
            if (isActive) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value:
                    task.status == DownloadStatus.pending || task.progress <= 0
                    ? null
                    : task.progress,
                minHeight: 5,
                borderRadius: BorderRadius.circular(5),
              ),
              const SizedBox(height: 4),
              Text(
                task.status == DownloadStatus.pending
                    ? l.downloadPreparing
                    : '${(task.progress * 100).round()}%',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
            if (task.status == DownloadStatus.error) ...[
              const SizedBox(height: 8),
              Text(
                task.wifiOnlyBlocked
                    ? l.downloadWifiOnlyRequired
                    : task.missingFile
                    ? l.downloadFileMissing
                    : task.quotaExceeded
                    ? l.downloadQuotaExceeded
                    : task.needsFreshLink
                    ? l.downloadFreshLinkRequired
                    : task.error ?? l.downloadFailed,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.error),
              ),
            ],
            if (task.status == DownloadStatus.cancelled &&
                task.needsFreshLink) ...[
              const SizedBox(height: 8),
              Text(
                l.downloadFreshLinkRequired,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                if (isComplete)
                  FilledButton.tonalIcon(
                    onPressed: () =>
                        openDownloadedFileExternally(context, ref, task),
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: Text(l.openFile),
                  )
                else if (task.canRetry)
                  FilledButton.tonalIcon(
                    // 重试沿用原来的来源与直链（#143）：外部源的任务不
                    // 传 presetUrl 会被当成 z 站下载，id 又对不上。
                    // #95：指定文件夹也沿用，落在同一个地方。
                    onPressed: () => ref
                        .read(downloadProvider.notifier)
                        .startDownload(
                          task.book,
                          presetUrl: task.presetUrl,
                          source: task.source,
                          customSubfolder: task.customSubfolder,
                        ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(l.retry),
                  )
                else if (task.status == DownloadStatus.paused)
                  TextButton.icon(
                    onPressed: () => ref
                        .read(downloadProvider.notifier)
                        .resumeDownload(task.id),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: Text(l.resumeDownload),
                  )
                else if (isActive) ...[
                  // 暂停：网络层立即停，.part 保留（继续时断点续传）。
                  TextButton.icon(
                    onPressed: () => ref
                        .read(downloadProvider.notifier)
                        .pauseDownload(task.id),
                    icon: const Icon(Icons.pause_rounded, size: 18),
                    label: Text(l.pauseDownload),
                  ),
                  TextButton.icon(
                    onPressed: () => ref
                        .read(downloadProvider.notifier)
                        .cancelDownload(task.id),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: Text(l.cancel),
                  ),
                ],
                const Spacer(),
                PopupMenuButton<String>(
                  tooltip: l.more,
                  onSelected: (value) =>
                      handleDownloadMenuAction(context, ref, task, value),
                  itemBuilder: (_) => [
                    // 排队中（pending）可置顶（E2）：下一个空出的槽位
                    // 给这本。
                    if (task.status == DownloadStatus.pending)
                      PopupMenuItem(
                        value: 'pin',
                        child: Text(l.downloadPinToTop),
                      ),
                    if (isComplete) ...[
                      PopupMenuItem(
                        value: 'category',
                        child: Text(l.shelfAddToCategory),
                      ),
                      PopupMenuItem(
                        value: 'details',
                        child: Text(l.fileDetails),
                      ),
                      PopupMenuItem(value: 'share', child: Text(l.share)),
                      const PopupMenuDivider(),
                    ],
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        isComplete
                            ? l.downloadDeleteFile
                            : l.downloadRemoveRecord,
                      ),
                    ),
                  ],
                  icon: const Icon(Icons.more_horiz_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme cs) => ColoredBox(
    color: cs.surfaceContainerHighest,
    child: Icon(Icons.menu_book_rounded, color: cs.onSurfaceVariant),
  );

  Widget _statusLabel(
    BuildContext context,
    AppLocalizations l,
    DownloadTask task,
  ) {
    final (label, color) = switch (task.status) {
      DownloadStatus.pending => (
        l.downloadPreparing,
        Theme.of(context).colorScheme.primary,
      ),
      DownloadStatus.downloading => (
        l.downloading,
        Theme.of(context).colorScheme.primary,
      ),
      DownloadStatus.paused => (
        l.pauseDownload,
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      DownloadStatus.completed => (l.completed, AppColors.success),
      DownloadStatus.error => (
        l.downloadFailed,
        Theme.of(context).colorScheme.error,
      ),
      DownloadStatus.cancelled => (
        l.downloadCancelled,
        Theme.of(context).colorScheme.outline,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// File-size label shared by the list row, the bookshelf card and
/// the file-details dialog.
String _formatSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

Future<bool> downloadTaskFileExists(
  BuildContext context,
  WidgetRef ref,
  DownloadTask task,
) async {
  final path = task.filePath;
  if (path != null && await MediaStoreFiles.exists(path)) return true;
  ref.read(downloadProvider.notifier).markMissingFile(task.id);
  if (context.mounted) {
    showAppSnack(context, AppLocalizations.of(context)!.downloadFileMissing);
  }
  return false;
}

Future<void> openDownloadedFileExternally(
  BuildContext context,
  WidgetRef ref,
  DownloadTask task,
) async {
  if (!await downloadTaskFileExists(context, ref, task)) return;
  try {
    // MediaStore-published downloads live at a content:// URI, which
    // OpenFilex cannot open — those go through the platform channel.
    if (MediaStoreFiles.isContentUri(task.filePath!)) {
      final opened = await MediaStoreFiles.open(task.filePath!);
      if (!opened && context.mounted) {
        showAppSnack(context, AppLocalizations.of(context)!.openFileFailed);
      }
      return;
    }
    final result = await OpenFilex.open(task.filePath!);
    if (result.type != ResultType.done && context.mounted) {
      showAppSnack(context, result.message);
    }
  } catch (error) {
    if (context.mounted) {
      showAppSnack(
        context,
        friendlyErrorText(error, AppLocalizations.of(context)!),
      );
    }
  }
}

Future<void> handleDownloadMenuAction(
  BuildContext context,
  WidgetRef ref,
  DownloadTask task,
  String action,
) async {
  final l = AppLocalizations.of(context)!;
  switch (action) {
    case 'pin':
      // E2：pending 任务置顶——slot 池插队，下一个空出的槽位给它。
      ref.read(downloadProvider.notifier).pinToTop(task.id);
      return;
    case 'category':
      // 归类进与书架同一棵分类树（方案 C1）：键 `download:<bookId>`。
      // 删除下载记录不清归属——重新下载回来还在原分类里。
      await showKeysCategoryPicker(
        context,
        ref,
        ['download:${task.id}'],
        current: ref
            .read(shelfCategoriesProvider)
            .assignments['download:${task.id}'],
      );
      return;
    case 'details':
      if (!context.mounted) return;
      // #123 follow-up：先把 content:// URI 解析成真实路径再显示；
      // 解析不到（文件已删等）就回退到原来存的路径。
      final storedPath = task.filePath ?? '';
      final displayPath = storedPath.isEmpty
          ? ''
          : (await MediaStoreFiles.realPath(storedPath) ?? storedPath);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(l.fileDetails),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(task.book.title),
              const SizedBox(height: 8),
              if (task.fileSize != null) Text(_formatSize(task.fileSize!)),
              if (task.downloadedAt != null)
                Text(formatDownloadDate(task.downloadedAt!)),
              const SizedBox(height: 8),
              // 点路径跳文件管理器（文件所在目录）；复制走下面的按钮。
              InkWell(
                onTap: () async {
                  final folder = downloadRelativeFolder(displayPath);
                  final ok = folder != null
                      ? await openFolder(folder)
                      : await openDownloadFolder();
                  if (!context.mounted) return;
                  if (ok) {
                    Navigator.pop(context);
                  } else {
                    showAppSnack(context, l.openFolderFailed);
                  }
                },
                child: Text(
                  displayPath,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            // #123：一点就把路径拷到剪贴板，不用长按选中再拷。
            // 拷的是真实路径（解析不到才拷原来存的）。
            if (displayPath.isNotEmpty)
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: displayPath),
                  );
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  showAppSnack(context, l.copiedToClipboard);
                },
                child: Text(l.copyPath),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.done),
            ),
          ],
        ),
      );
      return;
    case 'share':
      if (!await downloadTaskFileExists(context, ref, task)) return;
      // MediaStore-published downloads live at a content:// URI,
      // which share_plus cannot share as a file path — those are
      // copied to a temp file in the app cache dir first.
      final sharePath = await MediaStoreFiles.shareablePath(task.filePath!);
      if (sharePath == null) {
        if (context.mounted) {
          showAppSnack(context, l.shareFailed);
        }
        return;
      }
      try {
        await SharePlus.instance.share(
          ShareParams(files: [XFile(sharePath)], text: task.book.title),
        );
      } catch (error) {
        if (context.mounted) {
          showAppSnack(context, l.shareFailed);
        }
      }
      return;
    case 'delete':
      await confirmDeleteDownload(context, ref, task);
      return;
  }
}

Future<void> confirmDeleteDownload(
  BuildContext context,
  WidgetRef ref,
  DownloadTask task,
) async {
  final l = AppLocalizations.of(context)!;
  final confirmed = await showConfirmDialog(
    context,
    title: task.status == DownloadStatus.completed
        ? l.downloadDeleteFile
        : l.downloadRemoveRecord,
    message: task.status == DownloadStatus.completed
        ? l.deleteDesc
        : l.downloadRemoveRecordHint,
    confirmLabel: l.delete,
    cancelLabel: l.cancel,
  );
  if (!confirmed) return;
  unawaited(HapticFeedback.mediumImpact());
  try {
    await ref.read(downloadProvider.notifier).removeTask(task.id);
  } catch (error) {
    if (context.mounted) {
      showAppSnack(context, l.downloadDeleteFailed);
    }
  }
}
