import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';

/// How the user wants to continue when the current Z-Library account
/// has no downloads left today.
enum QuotaExhaustedChoice {
  /// Switch to another account and download from Z-Library under
  /// that account's quota (same file).
  switchAccount,

  /// Download the book from LibGen / Anna's Archive instead (a
  /// different copy of the same book).
  switchSource,

  /// Do nothing.
  cancel,
}

/// Quota-exhausted prompt: the two ways to keep downloading, side by
/// side — switch accounts, or switch sources.
/// （awesome_dialog 退役：全 app 确认弹统一 M3 AlertDialog。）
Future<QuotaExhaustedChoice> showQuotaExhaustedDialog(
  BuildContext context,
) async {
  final l10n = AppLocalizations.of(context)!;
  final choice = await showDialog<QuotaExhaustedChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.downloadQuotaTitle),
      content: Text(l10n.downloadQuotaDesc),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(
            dialogContext,
            QuotaExhaustedChoice.cancel,
          ),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            dialogContext,
            QuotaExhaustedChoice.switchSource,
          ),
          child: Text(l10n.quotaFallbackSwitchSource),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            dialogContext,
            QuotaExhaustedChoice.switchAccount,
          ),
          child: Text(l10n.switchAccount),
        ),
      ],
    ),
  );
  return choice ?? QuotaExhaustedChoice.cancel;
}
