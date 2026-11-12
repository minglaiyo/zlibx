import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/download_provider.dart';
import '../../services/media_store.dart';
import '../../theme/app_colors.dart';
import '../../utils/cover_cache.dart';
import '../../utils/file_utils.dart';
import '../../widgets/empty_state.dart';

import '../../utils/app_snack.dart';
import '../../utils/date_text.dart';
class LocalDownloadsScreen extends ConsumerWidget {
  const LocalDownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                  appBar.preferredSize.height + MediaQuery.paddingOf(context).top,
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
                  _DownloadList(
                    taskIds: completedIds,
                    emptyIcon: Icons.check_circle_outline_rounded,
                    emptyTitle: l.noCompletedDownloads,
                    emptyMessage: l.downloadedBooksHere,
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
    return ListView.separated(
      // Bottom 124 = 28 gap + 96 floating-nav clearance, reserved
      // inside the list so items scroll behind the pill (like the
      // home grid).
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 124),
      itemCount: taskIds.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, index) => _DownloadItem(id: taskIds[index]),
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
    final details = [
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
                task.missingFile
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
                    onPressed: () => _openFile(context, ref, task),
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: Text(l.openFile),
                  )
                else if (task.canRetry)
                  FilledButton.tonalIcon(
                    onPressed: () => ref
                        .read(downloadProvider.notifier)
                        .startDownload(task.book),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(l.retry),
                  )
                else if (isActive)
                  TextButton.icon(
                    onPressed: () => ref
                        .read(downloadProvider.notifier)
                        .cancelDownload(task.id),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: Text(l.cancel),
                  ),
                const Spacer(),
                PopupMenuButton<String>(
                  tooltip: l.more,
                  onSelected: (value) => _onMenu(context, ref, task, value),
                  itemBuilder: (_) => [
                    if (isComplete) ...[
                      PopupMenuItem(
                        value: 'details',
                        child: Text(l.fileDetails),
                      ),
                      PopupMenuItem(
                        value: 'share',
                        child: Text(l.share),
                      ),
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
      DownloadStatus.downloading => (l.downloading, Theme.of(context).colorScheme.primary),
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

  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  Future<bool> _fileExists(
    BuildContext context,
    WidgetRef ref,
    DownloadTask task,
  ) async {
    final path = task.filePath;
    if (path != null && await MediaStoreFiles.exists(path)) return true;
    ref.read(downloadProvider.notifier).markMissingFile(task.id);
    if (context.mounted) {
      showAppSnack(context,
            AppLocalizations.of(context)!.downloadFileMissing,
          );
    }
    return false;
  }

  Future<void> _openFile(
    BuildContext context,
    WidgetRef ref,
    DownloadTask task,
  ) async {
    if (!await _fileExists(context, ref, task)) return;
    try {
      // MediaStore-published downloads live at a content:// URI, which
      // OpenFilex cannot open — those go through the platform channel.
      if (MediaStoreFiles.isContentUri(task.filePath!)) {
        final opened = await MediaStoreFiles.open(task.filePath!);
        if (!opened && context.mounted) {
          showAppSnack(context,
                AppLocalizations.of(context)!.openFileFailed,
              );
        }
        return;
      }
      final result = await OpenFilex.open(task.filePath!);
      if (result.type != ResultType.done && context.mounted) {
        showAppSnack(context, result.message);
      }
    } catch (error) {
      if (context.mounted) {
        showAppSnack(context, error.toString());
      }
    }
  }

  Future<void> _onMenu(
    BuildContext context,
    WidgetRef ref,
    DownloadTask task,
    String action,
  ) async {
    final l = AppLocalizations.of(context)!;
    switch (action) {
      case 'details':
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
                SelectableText(task.filePath ?? ''),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l.done),
              ),
            ],
          ),
        );
        return;
      case 'share':
        if (!await _fileExists(context, ref, task)) return;
        // MediaStore-published downloads live at a content:// URI,
        // which share_plus cannot share as a file path — those are
        // copied to a temp file in the app cache dir first.
        final sharePath = await MediaStoreFiles.shareablePath(
          task.filePath!,
        );
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
        await _confirmDelete(context, ref, task);
        return;
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    DownloadTask task,
  ) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          task.status == DownloadStatus.completed
              ? l.downloadDeleteFile
              : l.downloadRemoveRecord,
        ),
        content: Text(
          task.status == DownloadStatus.completed
              ? l.deleteDesc
              : l.downloadRemoveRecordHint,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(downloadProvider.notifier).removeTask(task.id);
    } catch (error) {
      if (context.mounted) {
        showAppSnack(context, l.downloadDeleteFailed);
      }
    }
  }

}
