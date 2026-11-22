import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../auth/widgets/account_manager_sheet.dart';

/// Quota-exhausted prompt: the current Z-Library account has no
/// downloads left today, and no other source has the book either.
///
/// Returns true when the user switched to another account, so the
/// caller can retry the download under that account's quota.
/// （awesome_dialog 退役：全 app 确认弹统一 M3 AlertDialog。）
Future<bool> showDownloadQuotaDialog(
  BuildContext context, {
  String? currentUserId,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final switchAccount = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.downloadQuotaTitle),
      content: Text(l10n.downloadQuotaDesc),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.confirmOk),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.switchAccount),
        ),
      ],
    ),
  );
  if (switchAccount != true || !context.mounted) return false;
  final result = await showAccountManagerSheet(
    context,
    currentUserId: currentUserId,
  );
  return result == AccountManagerResult.switched;
}
