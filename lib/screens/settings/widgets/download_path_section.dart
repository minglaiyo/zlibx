import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/settings_provider.dart';
import '../../../services/saf_folder_access.dart';
import '../../../utils/app_snack.dart';
import '../../../utils/file_utils.dart';
import 'section_header.dart';
import 'settings_card.dart';


class DownloadPathSection extends ConsumerWidget {
  const DownloadPathSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final wifiOnly = ref.watch(wifiOnlyDownloadsProvider);
    final organizeMode = ref.watch(downloadOrganizeModeProvider);
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
        // 自动分文件夹：新下载的书按作者或分类放进子文件夹；只对
        // 新下载生效，已下载的文件不会移动。
        SettingsCard(
          child: ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
            title: Text(l10n.downloadOrganize),
            subtitle: Text(_organizeModeLabel(l10n, organizeMode)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showOrganizeModeDialog(context, ref),
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
        // SAF 文件夹授权：清数据前下载的书会变孤儿（app 能看见文件但
        // 打不开），授权 Download/zlibx 文件夹后才能重新打开它们。
        // 只在 Android 上出现（其他平台没有这套存储模型）。
        if (Platform.isAndroid) ...[
          const SizedBox(height: 12),
          const _SafFolderTile(),
        ],
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

  String _organizeModeLabel(
    AppLocalizations l10n,
    DownloadOrganizeMode mode,
  ) => switch (mode) {
    DownloadOrganizeMode.off => l10n.downloadOrganizeOff,
    DownloadOrganizeMode.author => l10n.downloadOrganizeAuthor,
    DownloadOrganizeMode.category => l10n.downloadOrganizeCategory,
  };

  String _organizeModeDesc(
    AppLocalizations l10n,
    DownloadOrganizeMode mode,
  ) => switch (mode) {
    DownloadOrganizeMode.off => l10n.downloadOrganizeOffDesc,
    DownloadOrganizeMode.author => l10n.downloadOrganizeAuthorDesc,
    DownloadOrganizeMode.category => l10n.downloadOrganizeCategoryDesc,
  };

  /// Organize-mode picker, in the project's own dialog idiom (see the
  /// domain selector): dense ListTile rows, the selected row marked
  /// with a leading check_circle in the primary color and a bold
  /// primary title. Tapping a row applies the mode and closes.
  void _showOrganizeModeDialog(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.read(downloadOrganizeModeProvider);
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final cs = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          title: Text(
            l10n.downloadOrganize,
            style: const TextStyle(fontSize: 18),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  l10n.downloadOrganizeDesc,
                  style: Theme.of(dialogContext).textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
              ...DownloadOrganizeMode.values.map((mode) {
                final selected = mode == current;
                return ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -2),
                  leading: selected
                      ? Icon(Icons.check_circle, color: cs.primary, size: 20)
                      : const Icon(
                          Icons.circle_outlined,
                          size: 20,
                          color: Colors.grey,
                        ),
                  title: Text(
                    _organizeModeLabel(l10n, mode),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected
                          ? FontWeight.w700
                          : FontWeight.normal,
                      color: selected ? cs.primary : null,
                    ),
                  ),
                  subtitle: Text(
                    _organizeModeDesc(l10n, mode),
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
                  onTap: () {
                    ref
                        .read(downloadOrganizeModeProvider.notifier)
                        .setMode(mode);
                    Navigator.pop(dialogContext);
                  },
                );
              }),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.close),
            ),
          ],
        );
      },
    );
  }

  void _showDownloadPathDialog(BuildContext context, WidgetRef ref) {    unawaited(
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

/// SAF 文件夹授权行：显示 Download/zlibx 文件夹有没有授权；点了打开
/// 系统文件夹选择器（已授权时点了可改选）。授权状态在进入页面和从
/// 系统设置/选择器回来时重查（WidgetsBindingObserver）。
class _SafFolderTile extends StatefulWidget {
  const _SafFolderTile();

  @override
  State<_SafFolderTile> createState() => _SafFolderTileState();
}

class _SafFolderTileState extends State<_SafFolderTile>
    with WidgetsBindingObserver {
  final _saf = SafFolderAccess();
  bool? _granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final granted = await _saf.hasGrant;
    if (mounted) setState(() => _granted = granted);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final granted = _granted ?? false;
    return SettingsCard(
      child: ListTile(
        leading: const Icon(Icons.folder_shared_outlined),
        title: Text(l10n.safDownloadFolder),
        subtitle: Text(
          granted
              ? l10n.safDownloadFolderGrantedDesc
              : l10n.safDownloadFolderDesc,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await _saf.pickFolder();
          await _refresh();
        },
      ),
    );
  }
}
