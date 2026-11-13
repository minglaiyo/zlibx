import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';

/// 文件已存在提示（z-lib 详情栏与外部源详情栏共用）。此前两处各写一
/// 遍 AwesomeDialog（审查批：awesome_dialog 依赖整体退役，全 app 确认
/// 弹统一走 M3 AlertDialog）。
///
/// 返回值：true = 重新下载；false = 已在回调里打开现有文件；
/// null = 用户点遮罩/返回键关闭（什么都不做）。「打开文件」回调在
/// 对话框关闭后才执行——对话框活得比调用它的工具条久，回调内要先
/// 复查 `context.mounted`。
Future<bool?> showFileExistsDialog(
  BuildContext context, {
  required Future<void> Function() onOpenFile,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.fileExistsTitle),
      content: Text(l10n.fileExistsDesc),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.openFile),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.downloadAgain),
        ),
      ],
    ),
  ).then((again) async {
    if (again == false) {
      // The dialog outlives this bar: re-check before using context.
      if (context.mounted) await onOpenFile();
    }
    return again;
  });
}
