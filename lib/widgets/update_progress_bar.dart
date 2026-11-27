import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/generated/app_localizations.dart';
import '../services/app_update_downloader.dart';

/// 全局悬浮更新进度条（计划一第 14 项）：盖在所有页面底部，
/// 下载状态变化时刷新，不依赖当前页面。
///
/// 显示“正在下载更新… xx%”+ 进度条 + 暂停/继续 + 取消；
/// 下载完显示安装按钮（系统不允许时另有去设置的引导）；
/// 失败显示原因 + 重试。
class UpdateProgressBar extends ConsumerWidget {
  const UpdateProgressBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dl = ref.watch(updateDownloadProvider);
    if (dl.status == AppUpdateDownloadStatus.idle) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final notifier = ref.read(updateDownloadProvider.notifier);

    final percent = dl.progress == null
        ? null
        : (dl.progress! * 100).round();

    final String statusText;
    switch (dl.status) {
      case AppUpdateDownloadStatus.downloading:
        statusText = percent == null
            ? l10n.downloading
            : l10n.updateDownloading(percent);
      case AppUpdateDownloadStatus.paused:
        statusText = l10n.updateDownloadPaused;
      case AppUpdateDownloadStatus.completed:
        statusText = dl.needsUnknownSources
            ? l10n.updateInstallNotAllowed
            : l10n.updateDownloadComplete;
      case AppUpdateDownloadStatus.failed:
        statusText = switch (dl.error) {
          AppUpdateDownloadError.verify => l10n.updateVerifyFailed,
          AppUpdateDownloadError.signature => l10n.updateSignatureMismatch,
          _ => l10n.downloadFailed,
        };
      case AppUpdateDownloadStatus.idle:
        statusText = '';
    }

    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(16),
          color: cs.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.system_update,
                      size: 20,
                      color: cs.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        statusText,
                        style: theme.textTheme.bodyMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (dl.status == AppUpdateDownloadStatus.downloading)
                      IconButton(
                        tooltip: l10n.pauseDownload,
                        icon: const Icon(Icons.pause),
                        onPressed: notifier.pause,
                      ),
                    if (dl.status == AppUpdateDownloadStatus.paused)
                      IconButton(
                        tooltip: l10n.resumeDownload,
                        icon: const Icon(Icons.play_arrow),
                        onPressed: () => notifier.resume(),
                      ),
                    if (dl.status == AppUpdateDownloadStatus.downloading ||
                        dl.status == AppUpdateDownloadStatus.paused)
                      IconButton(
                        tooltip: l10n.cancel,
                        icon: const Icon(Icons.close),
                        onPressed: () => notifier.cancel(),
                      ),
                    if (dl.status == AppUpdateDownloadStatus.failed)
                      TextButton(
                        onPressed: () => notifier.retry(),
                        child: Text(l10n.retry),
                      ),
                    if (dl.status == AppUpdateDownloadStatus.completed &&
                        !dl.needsUnknownSources)
                      FilledButton(
                        onPressed: () => notifier.install(),
                        child: Text(l10n.updateInstall),
                      ),
                    if (dl.status == AppUpdateDownloadStatus.completed &&
                        dl.needsUnknownSources)
                      FilledButton(
                        onPressed: () => notifier.openInstallSettings(),
                        child: Text(l10n.updateOpenSettings),
                      ),
                    if (dl.status == AppUpdateDownloadStatus.failed ||
                        dl.status == AppUpdateDownloadStatus.completed)
                      IconButton(
                        tooltip: l10n.later,
                        icon: const Icon(Icons.close),
                        onPressed: notifier.dismiss,
                      ),
                  ],
                ),
                if (dl.status == AppUpdateDownloadStatus.downloading ||
                    dl.status == AppUpdateDownloadStatus.paused) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: dl.progress),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
