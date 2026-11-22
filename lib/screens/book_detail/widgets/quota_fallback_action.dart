import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/books_provider.dart';
import '../../../providers/download_provider.dart';
import '../../../services/quota_fallback.dart';
import '../../../utils/app_snack.dart';
import '../../auth/widgets/account_manager_sheet.dart';
import 'download_quota_dialog.dart';
import 'quota_fallback_confirm_dialog.dart';

/// Quota-exhausted download: the current account has no downloads left
/// today, so first ask the user how to continue — switch to another
/// account (same Z-Library file, that account's quota) or switch
/// sources (LibGen / Anna's Archive, a different copy of the same
/// book). Providers are read before the await so a disposed ref is
/// never touched after the search finishes.
///
/// Shared by the detail page's download-task listener (a started
/// download that dies on quota) and the action bar's pre-check (the
/// profile already shows 0 downloads left before any download starts).
Future<void> tryQuotaFallbackAndDownload(
  BuildContext context,
  WidgetRef ref,
  Book book,
) async {
  final l10n = AppLocalizations.of(context)!;
  final currentUserId = ref.read(authProvider).user?.id;
  final annasApi = ref.read(annasArchieveProvider);
  final libgenService = ref.read(libgenServiceProvider);
  final downloadNotifier = ref.read(downloadProvider.notifier);

  final choice = await showQuotaExhaustedDialog(context);
  if (!context.mounted || choice == QuotaExhaustedChoice.cancel) return;

  if (choice == QuotaExhaustedChoice.switchAccount) {
    final result = await showAccountManagerSheet(
      context,
      currentUserId: currentUserId,
    );
    if (result == AccountManagerResult.switched && context.mounted) {
      // The new account has its own daily quota: retry the
      // Z-Library download under it. (If it is exhausted too, the
      // engine fails on quota again and this prompt comes back.)
      unawaited(downloadNotifier.startDownload(book));
    }
    return;
  }

  // switchSource: try LibGen, then Anna's Archive.
  showAppSnack(context, l10n.quotaFallbackTrying);
  final result = await tryQuotaFallback(
    zBook: book,
    annasApi: annasApi,
    libgenService: libgenService,
  );
  if (!context.mounted) return;
  if (result == null) {
    showAppSnack(context, l10n.quotaFallbackNotFound);
    return;
  }
  // The fallback file is another source's copy of the same book — it
  // may differ in edition, scan quality and file size, so confirm
  // with the user before starting the download.
  final confirmed = await showQuotaFallbackConfirmDialog(context, result);
  if (!context.mounted || !confirmed) return;
  unawaited(
    downloadNotifier.startDownload(result.book, presetUrl: result.url),
  );
  showAppSnack(context, l10n.quotaFallbackSwitched);
}
