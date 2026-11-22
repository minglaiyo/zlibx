import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/books_provider.dart';
import '../../../providers/download_provider.dart';
import '../../../services/quota_fallback.dart';
import '../../../utils/app_snack.dart';
import 'download_quota_dialog.dart';

/// Quota-exhausted fallback: try LibGen / Anna's Archive for the same
/// book and continue the download there; when neither has it, show the
/// quota dialog as before. Providers are read before the await so a
/// disposed ref is never touched after the search finishes.
///
/// Shared by the detail page's download-task listener (a started
/// download that dies on quota) and the action bar's pre-check (the
/// profile already shows 0 downloads left before any download starts):
/// both used to show the dialog directly, so the pre-check path never
/// reached the fallback at all.
Future<void> tryQuotaFallbackAndDownload(
  BuildContext context,
  WidgetRef ref,
  Book book,
) async {
  final l10n = AppLocalizations.of(context)!;
  final annasApi = ref.read(annasArchieveProvider);
  final libgenService = ref.read(libgenServiceProvider);
  final downloadNotifier = ref.read(downloadProvider.notifier);
  showAppSnack(context, l10n.quotaFallbackTrying);
  final result = await tryQuotaFallback(
    zBook: book,
    annasApi: annasApi,
    libgenService: libgenService,
  );
  if (!context.mounted) return;
  if (result == null) {
    showDownloadQuotaDialog(context);
    return;
  }
  unawaited(
    downloadNotifier.startDownload(result.book, presetUrl: result.url),
  );
  showAppSnack(context, l10n.quotaFallbackSwitched);
}
