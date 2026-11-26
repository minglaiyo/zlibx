import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../services/app_restart.dart';
import '../../../services/backup_restore_service.dart';
import '../../../utils/app_snack.dart';
import '../../../utils/diagnostics.dart';
import 'section_header.dart';
import 'settings_card.dart';

/// 备份与恢复（计划一第 17 项）：设置页里的两个入口。
///
/// 导出：有敏感字段（登录会话 / Anna key）时先让用户设密码（输入 +
/// 确认），再把 zip 写临时文件走系统分享；没有敏感字段时直接导出，
/// 不问密码。导入：选 zip → 校验版本 → 带 secrets 信封时问密码 →
/// 确认覆盖 → 写回各 box，完成后弹重启提示，可点立即重启（整进程
/// 重启，内存里的 provider 状态随之刷新）或稍后手动重启。
class BackupRestoreSection extends ConsumerStatefulWidget {
  const BackupRestoreSection({super.key});

  @override
  ConsumerState<BackupRestoreSection> createState() =>
      _BackupRestoreSectionState();
}

class _BackupRestoreSectionState extends ConsumerState<BackupRestoreSection> {
  final BackupRestoreService _service = BackupRestoreService();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        SectionHeader(icon: Icons.backup_rounded, title: l.backupRestore),
        SettingsCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.file_upload_outlined),
                title: Text(l.backupExport),
                subtitle: Text(l.backupExportDesc),
                onTap: _busy ? null : _exportBackup,
              ),
              const SettingsDivider(),
              ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: Text(l.backupImport),
                subtitle: Text(l.backupImportDesc),
                onTap: _busy ? null : _importBackup,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _exportBackup() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final bool hasSecrets = await _service.hasSecrets();
      if (!mounted) {
        return;
      }
      final String? password =
          hasSecrets ? await _askPassword(setMode: true) : null;
      if (hasSecrets && password == null) {
        return;
      }
      final Uint8List bytes =
          await _service.exportBackup(password: password);
      if (!mounted) {
        return;
      }
      final AppLocalizations l = AppLocalizations.of(context)!;
      final String name = 'zlibx_backup_${_today()}.zip';
      final Directory dir =
          await Directory.systemTemp.createTemp('zlibx_backup_');
      final File file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes);
      if (!mounted) {
        return;
      }
      await SharePlus.instance.share(
        ShareParams(files: <XFile>[XFile(file.path)], text: l.backupExportDone),
      );
      if (!mounted) {
        return;
      }
      showAppSnack(context, l.backupExportDone);
    } on Object catch (error) {
      logIgnored('backup_export', error);
      if (!mounted) {
        return;
      }
      showAppSnack(
        context,
        AppLocalizations.of(context)!.backupExportFailed,
        error: true,
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _importBackup() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final List<PlatformFile> picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['zip'],
      );
      if (picked.isEmpty) {
        return;
      }
      final PlatformFile file = picked.first;
      final int? size = await file.length();
      if (size != null && size > BackupRestoreService.kBackupMaxBytes) {
        throw const BackupTooLargeException();
      }
      final Uint8List bytes = await file.xFile.readAsBytes();
      final BackupInfo info = await _service.peekBackup(bytes);
      if (!mounted) {
        return;
      }
      final String? password =
          info.hasSecrets ? await _askPassword(setMode: false) : null;
      if (info.hasSecrets && password == null) {
        return;
      }
      if (!mounted) {
        return;
      }
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) {
          final AppLocalizations dl = AppLocalizations.of(dialogContext)!;
          return AlertDialog(
            title: Text(dl.backupConfirmOverwriteTitle),
            content: Text(dl.backupConfirmOverwrite),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(dl.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(dl.backupImport),
              ),
            ],
          );
        },
      );
      if (confirmed != true) {
        return;
      }
      await _service.importBackup(bytes, password: password);
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) {
          final AppLocalizations dl = AppLocalizations.of(dialogContext)!;
          return AlertDialog(
            title: Text(dl.backupImportDone),
            content: Text(dl.backupRestartNote),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(dl.later),
              ),
              FilledButton(
                onPressed: () async {
                  final bool ok = await AppRestart.restart();
                  if (!ok && mounted && dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                    showAppSnack(
                      context,
                      AppLocalizations.of(context)!.appRestartFailed,
                      error: true,
                    );
                  }
                },
                child: Text(dl.restartNow),
              ),
            ],
          );
        },
      );
    } on BackupWrongPasswordException catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnack(
        context,
        AppLocalizations.of(context)!.backupWrongPassword,
        error: true,
      );
    } on BackupUnsupportedVersionException catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnack(
        context,
        AppLocalizations.of(context)!.backupUnsupportedVersion,
        error: true,
      );
    } on BackupTooLargeException catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnack(
        context,
        AppLocalizations.of(context)!.backupTooLarge,
        error: true,
      );
    } on BackupInvalidFileException catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnack(
        context,
        AppLocalizations.of(context)!.backupInvalidFile,
        error: true,
      );
    } on BackupPasswordRequiredException catch (_) {
      // 正常流程走不到这里（peek 已先报 hasSecrets）；真走到就是
      // 文件本身有问题。
      if (!mounted) {
        return;
      }
      showAppSnack(
        context,
        AppLocalizations.of(context)!.backupInvalidFile,
        error: true,
      );
    } on Object catch (error) {
      logIgnored('backup_import', error);
      if (!mounted) {
        return;
      }
      showAppSnack(
        context,
        AppLocalizations.of(context)!.backupImportFailed,
        error: true,
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// 问密码。setMode=true 是导出设密码（密码 + 确认 + 提示文案），
  /// false 是导入输密码（只一个框）。取消返回 null。
  Future<String?> _askPassword({required bool setMode}) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) =>
          _BackupPasswordDialog(setMode: setMode),
    );
  }

  String _today() {
    final DateTime now = DateTime.now();
    final String month = now.month.toString().padLeft(2, '0');
    final String day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }
}

/// 备份密码对话框：设密码（两框 + 提示）或输密码（一框）。
/// 密码只存在内存里，绝不写日志、不落盘。
class _BackupPasswordDialog extends StatefulWidget {
  const _BackupPasswordDialog({required this.setMode});

  final bool setMode;

  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context)!;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.setMode ? l.backupSetPassword : l.backupEnterPassword),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l.backupPassword,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
          ),
          if (widget.setMode) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _confirmController,
              obscureText: _obscureConfirm,
              decoration: InputDecoration(
                labelText: l.backupPasswordConfirm,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureConfirm ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l.backupPasswordHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: cs.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.setMode ? l.save : l.backupImport),
        ),
      ],
    );
  }

  void _submit() {
    final AppLocalizations l = AppLocalizations.of(context)!;
    final String password = _passwordController.text;
    if (password.isEmpty) {
      setState(() => _error = l.backupPasswordEmpty);
      return;
    }
    if (widget.setMode && password != _confirmController.text) {
      setState(() => _error = l.backupPasswordMismatch);
      return;
    }
    Navigator.of(context).pop(password);
  }
}
