import 'dart:async';
import 'package:flutter/material.dart';
import '../../../l10n/generated/app_localizations.dart';

/// 用户自己 Z 站账号当日下载次数用尽时的提醒弹窗。
/// （awesome_dialog 退役：全 app 确认弹统一 M3 AlertDialog。）
void showDownloadQuotaDialog(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  unawaited(showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.downloadQuotaTitle),
      content: Text(l10n.downloadQuotaDesc),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.confirmOk),
        ),
      ],
    ),
  ));
}
