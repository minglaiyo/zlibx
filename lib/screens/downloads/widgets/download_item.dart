/// One download row (P1-4 split of local_downloads_screen.dart):
/// cover, title, details, progress / error text and the bottom
/// actions (open / retry / pause / resume / cancel + the "…" menu:
/// pin, category, details, share, delete).
library;

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/display_book.dart';
import '../../../providers/download_provider.dart';
import '../../../providers/shelf_categories_provider.dart';
import '../../../screens/favorites/category_actions.dart';
import '../../../services/media_store.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/app_snack.dart';
import '../../../utils/cover_cache.dart';
import '../../../utils/date_text.dart';
import '../../../utils/error_text.dart';
import '../../../utils/file_utils.dart';
import '../../../widgets/confirm_dialog.dart';

class DownloadItem extends ConsumerWidget {
  const DownloadItem({super.key, required this.id});

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
                    : task.magicMismatch
                    ? l.downloadMagicMismatch
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
                  onSelected: (value) => _onMenu(context, ref, task, value),
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
      showAppSnack(context, AppLocalizations.of(context)!.downloadFileMissing);
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
          showAppSnack(context, AppLocalizations.of(context)!.openFileFailed);
        }
        return;
      }
      final result = await OpenFilex.open(
        task.filePath!,
        type: MediaStoreFiles.mimeTypeForPath(task.filePath!),
      );
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

  Future<void> _onMenu(
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
        if (!await _fileExists(context, ref, task)) return;
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
}
