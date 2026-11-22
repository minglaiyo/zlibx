import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/display_book.dart' show BookSource;
import '../../../services/quota_fallback.dart';

/// Confirmation before a quota-fallback download starts.
///
/// The file comes from another source (LibGen / Anna's Archive) and is a
/// different copy of the same book: the edition, scan quality and file
/// size may differ from the Z-Library version. Returns true when the
/// user confirms, false on cancel or dismiss.
Future<bool> showQuotaFallbackConfirmDialog(
  BuildContext context,
  QuotaFallbackResult result,
) async {
  final l10n = AppLocalizations.of(context)!;
  final sourceName = result.source == BookSource.libgen
      ? l10n.sourceLibgen
      : l10n.sourceAnnasArchive;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.quotaFallbackConfirmTitle),
      content: Text(
        l10n.quotaFallbackConfirmDesc(
          sourceName,
          (result.book.extension ?? 'epub').toUpperCase(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.download),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
