import 'package:flutter/material.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../l10n/generated/app_localizations.dart';

/// What the user picked when the formats lookup failed: retry the
/// lookup, download the format already on the page, or nothing
/// (dialog dismissed).
enum DownloadFormatErrorAction { retry, downloadCurrent }

/// The menu entries for the format picker: the server's list, with
/// the format already on the detail page first when it is not in the
/// list — the menu must never take away the download the page
/// already offers. Entries are matched by (id, hash); the server
/// list's own order is kept after the prepended entry.
List<BookFormat> downloadFormatChoices({
  required Book book,
  required List<BookFormat> formats,
}) {
  final hash = book.hash ?? '';
  final alreadyListed = formats.any(
    (f) => f.id == book.id && f.hash == hash,
  );
  if (alreadyListed) return List.of(formats);
  return [
    BookFormat(
      id: book.id,
      hash: hash,
      extension: (book.extension ?? 'epub').toLowerCase(),
      filesize: book.filesize,
      filesizeString: book.filesizeString,
    ),
    ...formats,
  ];
}

/// Format picker (plan item 2): one row per format (extension +
/// size), the row for the page's own format marked "current".
/// Returns the picked format, or null when dismissed.
Future<BookFormat?> showDownloadFormatDialog(
  BuildContext context, {
  required List<BookFormat> formats,
  required int currentBookId,
  required String currentHash,
}) async {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<BookFormat>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.downloadFormatsTitle),
      contentPadding: const EdgeInsets.only(top: 12, bottom: 8),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: formats.length,
          itemBuilder: (context, index) {
            final format = formats[index];
            final isCurrent =
                format.id == currentBookId && format.hash == currentHash;
            final size =
                format.filesizeString ?? _formatBytes(format.filesize);
            return ListTile(
              title: Text(format.extension.toUpperCase()),
              subtitle: size == null ? null : Text(size),
              trailing: isCurrent
                  ? Text(
                      l10n.downloadFormatsCurrent,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    )
                  : null,
              onTap: () => Navigator.pop(dialogContext, format),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.cancel),
        ),
      ],
    ),
  );
}

/// Formats lookup failed: show the error with a retry — never read a
/// failure as "no other formats". Returns the action, or null when
/// dismissed.
Future<DownloadFormatErrorAction?> showDownloadFormatErrorDialog(
  BuildContext context, {
  required String error,
}) async {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<DownloadFormatErrorAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.downloadFormatsFailed),
      content: Text(error),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, DownloadFormatErrorAction.retry),
          child: Text(l10n.retry),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            dialogContext,
            DownloadFormatErrorAction.downloadCurrent,
          ),
          child: Text(l10n.downloadCurrentFormat),
        ),
      ],
    ),
  );
}

/// Bytes → "12.3 MB" for entries that only sent a raw size.
String? _formatBytes(int? bytes) {
  if (bytes == null || bytes < 0) return null;
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024.0;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}
