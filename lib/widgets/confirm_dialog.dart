import 'package:flutter/material.dart';

/// 确认弹窗的单一实现（审查批：此前 6 处各写一遍 AlertDialog，破坏性
/// 按钮有的还是普通 TextButton——审查批 UI 一致性发现 5）。破坏性确认
/// 用 error 底的 FilledButton（与账号管理弹窗的既有先例一致），取消
/// 用 TextButton。返回 true = 确认，false / 关闭 = 取消。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required String cancelLabel,
  String? message,
  bool destructive = true,
}) async {
  final cs = Theme.of(context).colorScheme;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: (message == null || message.isEmpty)
          ? null
          : Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: cs.error)
              : null,
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
