import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:async';
import 'dart:io';
import '../../../providers/settings_provider.dart';
import '../../../utils/file_utils.dart';
import 'section_header.dart';
import 'settings_card.dart';
import '../../../l10n/generated/app_localizations.dart';

import '../../../utils/app_snack.dart';

class DownloadPathSection extends ConsumerWidget {
  const DownloadPathSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final wifiOnly = ref.watch(wifiOnlyDownloadsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        SectionHeader(icon: Icons.download_rounded, title: l10n.downloads),
        SettingsCard(
          child: ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(l10n.downloadDirectory),
            subtitle: _buildSubtitle(context, ref),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showDownloadPathDialog(context, ref),
          ),
        ),
        const SizedBox(height: 12),
        // 仅 Wi-Fi 下载（方案 E1）：发起/恢复/重试在计费连接上被拒绝，
        // 任务记为带旗标的错误态；已在进行的下载不受影响。
        SettingsCard(
          child: SwitchListTile(
            title: Text(l10n.wifiOnlyDownloads),
            subtitle: Text(
              l10n.wifiOnlyDownloadsDesc,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            value: wifiOnly,
            isThreeLine: true,
            activeThumbColor: cs.primary,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            onChanged: (value) =>
                ref.read(wifiOnlyDownloadsProvider.notifier).setEnabled(value),
          ),
        ),
      ],
    );
  }

  Widget _buildSubtitle(BuildContext context, WidgetRef ref) {
    if (Platform.isAndroid) {
      return Text(
        AppLocalizations.of(context)!.systemDownloadsMediastore,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    final path = ref.watch(downloadPathProvider);
    final displayPath = (path != null && path.isNotEmpty)
        ? path
        : (AppLocalizations.of(context)!.defaultAppDocuments);
    return Text(displayPath, maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  void _showDownloadPathDialog(BuildContext context, WidgetRef ref) {
    unawaited(
      showModalBottomSheet(
        context: context,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // On Android 10+, MediaStore handles downloads automatically
                if (Platform.isAndroid) ...[
                  ListTile(
                    leading: Icon(
                      Icons.download,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: Text(
                      AppLocalizations.of(context)!.systemDownloadsFolder,
                    ),
                    subtitle: Text(
                      AppLocalizations.of(context)!.mediastoreDesc,
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        AppLocalizations.of(context)!.recommended,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: Colors.blue[700],
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              AppLocalizations.of(context)!.downloadsSavedHint,
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.blue[700],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final success = await openDownloadFolder();
                              if (!success && context.mounted) {
                                showAppSnack(
                                  context,
                                  AppLocalizations.of(
                                    context,
                                  )!.cannotOpenFolder,
                                );
                              } else if (context.mounted) {
                                Navigator.pop(context);
                              }
                            },
                            icon: const Icon(Icons.folder_open),
                            label: Text(
                              AppLocalizations.of(context)!.openDownloadFolder,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  // On desktop platforms, use file picker
                  ListTile(
                    leading: Icon(
                      Icons.folder_open,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: Text(AppLocalizations.of(context)!.selectFolder),
                    subtitle: Text(
                      AppLocalizations.of(context)!.chooseCustomDownloadDir,
                    ),
                    onTap: () async {
                      Navigator.pop(context);
                      // file_picker 13.3：getDirectoryPath 已废弃，新 API
                      // pickDirectory 返回 Uri——file scheme 转回本地路径
                      // （桌面自选目录场景），其他 scheme 原样交给存储层。
                      final picked = await FilePicker.pickDirectory();
                      final result = picked?.scheme == 'file'
                          ? picked!.toFilePath()
                          : picked?.toString();
                      if (result != null && result.isNotEmpty) {
                        await ref
                            .read(downloadPathProvider.notifier)
                            .setDownloadPath(result);
                        if (context.mounted) {
                          // 成功提示保留绿色背景的既有视觉，只统一入口。
                          showAppSnackRaw(
                            context,
                            SnackBar(
                              content: Text(
                                AppLocalizations.of(
                                  context,
                                )!.downloadDirUpdated,
                              ),
                              backgroundColor: Colors.green,
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      }
                    },
                  ),
                  ListTile(
                    leading: Icon(
                      Icons.restore,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    title: Text(AppLocalizations.of(context)!.resetToDefault),
                    subtitle: Text(
                      AppLocalizations.of(context)!.useDefaultDocumentsDir,
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      ref
                          .read(downloadPathProvider.notifier)
                          .clearDownloadPath();
                      showAppSnack(
                        context,
                        AppLocalizations.of(context)!.resetToDefaultDirDone,
                      );
                    },
                  ),
                ],
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(AppLocalizations.of(context)!.close),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
