import 'dart:async';
// Bottom action bar for external (Anna's Archive / LibGen) detail pages.
//
// Unlike the z-lib bar (book_action_bar.dart), this one has no quota
// check, no account and no online reader: the only action is Download.
// Tapping it first resolves a URL through external_download.dart
// (LibGen get.php → Anna fast download with the donation key →
// slow-link extraction) and then hands the URL to the existing
// DownloadNotifier.startDownload(book, presetUrl: url) direct-link
// branch. The synthesized vendor Book (Option A) is built from the
// detail page's BookInfoData, so the task id, file name and download
// history all key on externalBookId(md5).
import 'package:zlibx/utils/diagnostics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:open_filex/open_filex.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'file_exists_dialog.dart';
import '../../../models/display_book.dart';
import '../../../providers/download_provider.dart';
import '../../../services/annas_archieve.dart';
import '../../../services/external_download.dart';
import '../../../services/media_store.dart';
import '../../../utils/app_snack.dart';

class ExternalBookActionBar extends ConsumerStatefulWidget {
  final DisplayBook displayBook;
  final BookInfoData info;

  const ExternalBookActionBar({
    super.key,
    required this.displayBook,
    required this.info,
  });

  @override
  ConsumerState<ExternalBookActionBar> createState() =>
      _ExternalBookActionBarState();
}

class _ExternalBookActionBarState
    extends ConsumerState<ExternalBookActionBar> {
  bool _resolving = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final cs = theme.colorScheme;
    // Same synthetic Book the download engine and the detail page's
    // progress lookup use; cheap to rebuild (pure value mapping).
    final book = synthesizeExternalBook(widget.info);
    // Per-book watch: only this book's task rebuilds the bar, not every
    // progress tick of every other download.
    final DownloadTask? downloadTask =
        ref.watch(downloadTaskProvider(book.id.toString()));

    final isDownloading = downloadTask?.status == DownloadStatus.downloading;
    final isCompleted = downloadTask?.status == DownloadStatus.completed;

    final IconData icon;
    final String label;
    if (isCompleted) {
      icon = Icons.folder_open_rounded;
      label = l10n.openFile;
    } else if (isDownloading) {
      icon = Icons.downloading_rounded;
      label = '${(downloadTask!.progress * 100).toStringAsFixed(0)}%';
    } else if (_resolving) {
      icon = Icons.download_rounded;
      label = l10n.resolvingDownloadLink;
    } else {
      icon = Icons.download_rounded;
      label = l10n.download;
    }

    final busy = _resolving || isDownloading;

    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        MediaQuery.of(context).padding.bottom + 12,
      ),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: ElevatedButton.icon(
                onPressed: busy
                    ? null
                    : () => _handleDownload(context, ref, book, downloadTask),
                icon: Icon(icon, size: 20),
                label: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      isCompleted ? cs.primaryContainer : cs.primary,
                  foregroundColor:
                      isCompleted ? cs.onPrimaryContainer : cs.onPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 14,
                  ),
                  elevation: 0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleDownload(
    BuildContext context,
    WidgetRef ref,
    Book book,
    DownloadTask? downloadTask,
  ) async {
    final isCompleted = downloadTask?.status == DownloadStatus.completed;
    if (isCompleted && downloadTask?.filePath != null) {
      await _openDownloadedFile(context, downloadTask!.filePath!);
      return;
    }

    // Same file-exists prompt as the z-lib bar: open the existing file
    // or re-download (which re-resolves a fresh link).
    final existingPath =
        await ref.read(downloadProvider.notifier).checkFileExists(book);
    if (existingPath != null && context.mounted) {
      final again = await showFileExistsDialog(
        context,
        onOpenFile: () => _openDownloadedFile(context, existingPath),
      );
      if (again != true) return;
      if (!context.mounted) return;
      await _resolveAndDownload(context, ref, book);
      return;
    }

    if (!context.mounted) return;
    await _resolveAndDownload(context, ref, book);
  }

  /// Resolves the download URL, then starts the existing direct-link
  /// download. The resolver never throws; a target without a URL means
  /// every route failed.
  Future<void> _resolveAndDownload(
    BuildContext context,
    WidgetRef ref,
    Book book,
  ) async {
    setState(() => _resolving = true);
    try {
      final target = await resolveExternalDownload(widget.info);
      if (!mounted) return;
      setState(() => _resolving = false);
      if (!target.hasUrl) {
        if (context.mounted) {
          _toast(context, AppLocalizations.of(context)!.downloadFailed);
        }
        return;
      }
      unawaited(
        ref
            .read(downloadProvider.notifier)
            .startDownload(book, presetUrl: target.url!),
      );
      if (context.mounted) {
        _toast(context, AppLocalizations.of(context)!.downloading);
      }
    } catch (error) {
      logIgnored('external_book_action_bar', error);
      if (!mounted) return;
      setState(() => _resolving = false);
      if (context.mounted) {
        _toast(context, AppLocalizations.of(context)!.downloadFailed);
      }
    }
  }

  /// Open a downloaded file. MediaStore-published downloads live at a
  /// content:// URI, which OpenFilex cannot open — those go through the
  /// platform channel (same pattern as local_downloads_screen.dart).
  /// Shows a snackbar when opening fails instead of failing silently.
  Future<void> _openDownloadedFile(BuildContext context, String path) async {
    try {
      if (MediaStoreFiles.isContentUri(path)) {
        final opened = await MediaStoreFiles.open(path);
        if (!opened && context.mounted) {
          _toast(
            context,
            AppLocalizations.of(context)!.openFileFailed,
          );
        }
        return;
      }
      final result = await OpenFilex.open(path);
      if (result.type != ResultType.done && context.mounted) {
        _toast(
          context,
          AppLocalizations.of(context)!.openFileFailed,
        );
      }
    } catch (error) {
      logIgnored('external_book_action_bar', error);
      if (context.mounted) {
        _toast(
          context,
          AppLocalizations.of(context)!.openFileFailed,
        );
      }
    }
  }

  void _toast(BuildContext context, String message) {
    showAppSnack(context, message);
  }
}
