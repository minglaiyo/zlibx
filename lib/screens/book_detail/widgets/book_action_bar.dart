import 'dart:async';
import 'package:zlibx/utils/diagnostics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:awesome_dialog/awesome_dialog.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import '../../../providers/download_provider.dart';
import '../../../providers/domain_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../services/media_store.dart';
import '../../../providers/update_provider.dart';
import '../../../routes/app_routes.dart';
import '../../../utils/app_snack.dart';
import '../../../utils/host_utils.dart';
import '../../../widgets/state_transition_switch.dart';
import '../../../widgets/update_dialog.dart';
import '../../reader/reader_screen.dart';
import 'download_quota_dialog.dart';

class BookActionBar extends ConsumerWidget {
  final Book book;
  final DownloadTask? downloadTask;
  final bool isDownloading;
  final bool isCompleted;

  /// Why the book is unavailable for download, or null when it is
  /// available: `'copyright'` or `'removed'` (see
  /// [BookDetailArgs.unavailableReason]). Removed books still open
  /// the detail page, but the download button is replaced by a
  /// disabled label — the site lists them without a file.
  final String? unavailableReason;

  const BookActionBar({
    super.key,
    required this.book,
    required this.downloadTask,
    required this.isDownloading,
    required this.isCompleted,
    this.unavailableReason,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final hasReadOnline =
        book.readOnlineUrl != null && book.readOnlineUrl!.isNotEmpty;

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
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          // ── Download Button (Secondary or Primary if no read) ──
          // Removed books get a disabled label instead: the file is
          // gone on the site, but the page itself stays reachable.
          Expanded(
            child: unavailableReason != null
                ? _buildUnavailableButton(
                    context,
                    unavailableReason == 'copyright'
                        ? l10n.copyrightRemoved
                        : l10n.removedBook,
                  )
                : _buildDownloadButton(
                    context,
                    ref,
                    l10n,
                    isPrimary: !hasReadOnline,
                  ),
          ),

          if (hasReadOnline) ...[
            const SizedBox(width: 12),

            // ── Read Button (Primary) ──
            Expanded(child: _buildReadButton(context, ref, l10n)),
          ],
        ],
      ),
    );
  }

  /// Disabled stand-in for the download button on removed books.
  Widget _buildUnavailableButton(BuildContext context, String label) {
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: ElevatedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.block_rounded, size: 20),
        label: Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: cs.surfaceContainerHighest,
          foregroundColor: cs.onSurfaceVariant,
          disabledBackgroundColor: cs.surfaceContainerHighest,
          disabledForegroundColor: cs.onSurfaceVariant,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          elevation: 0,
        ),
      ),
    );
  }

  Widget _buildDownloadButton(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n, {
    bool isPrimary = false,
  }) {
    final IconData icon;
    final String label;
    final cs = Theme.of(context).colorScheme;

    if (isCompleted) {
      icon = Icons.folder_open_rounded;
      label = l10n.openFile;
    } else if (isDownloading) {
      icon = Icons.downloading_rounded;
      label = '${(downloadTask!.progress * 100).toStringAsFixed(0)}%';
    } else {
      icon = Icons.download_rounded;
      label = l10n.download;
    }

    // 按钮状态切换做淡入淡出：key 只区分状态（完成 / 下载中 / 待下载），
    // 下载中的百分比用同一个 key，进度跳变不触发过渡。
    final stateKey = isCompleted
        ? 'completed'
        : isDownloading
        ? 'downloading'
        : 'idle';
    final iconWidget = StateTransitionSwitch(
      child: Icon(icon, size: 20, key: ValueKey(icon)),
    );
    final labelWidget = StateTransitionSwitch(
      child: Text(
        label,
        key: ValueKey(stateKey),
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );

    if (isPrimary) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: ElevatedButton.icon(
          onPressed: isDownloading ? null : () => _handleDownload(context, ref),
          icon: iconWidget,
          label: labelWidget,
          style: ElevatedButton.styleFrom(
            backgroundColor: isCompleted ? cs.primaryContainer : cs.primary,
            foregroundColor: isCompleted ? cs.onPrimaryContainer : cs.onPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            elevation: 0,
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: FilledButton.tonalIcon(
        onPressed: isDownloading ? null : () => _handleDownload(context, ref),
        icon: iconWidget,
        label: labelWidget,
        style: FilledButton.styleFrom(
          backgroundColor: cs.primaryContainer,
          foregroundColor: cs.onPrimaryContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        ),
      ),
    );
  }

  Widget _buildReadButton(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: ElevatedButton.icon(
        onPressed: () => _handleRead(context, ref),
        icon: const Icon(Icons.menu_book_rounded, size: 20),
        label: Text(
          l10n.preview,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          elevation: 0,
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════
  //  ACTION HANDLERS
  // ════════════════════════════════════════════════════════════
  void _handleRead(BuildContext context, WidgetRef ref) {
    final customDomain = ref.read(domainProvider);
    final authState = ref.read(authProvider);
    final user = authState.user;

    // Build the reader domain from the custom domain
    final readerDomain = readerDomainFor(customDomain);

    String url = book.readOnlineUrl!;
    url = url.replaceAll(RegExp(r'cdn\.reader\.'), 'reader.');
    url = url.replaceAll(RegExp(r'reader\.[a-zA-Z0-9.-]+'), readerDomain);
    url = url.replaceAll(RegExp(r'z-library\.[a-zA-Z]+'), customDomain);

    // 会话密钥绝不拼进 URL（query 会进 JS、Referer、历史与日志）。
    // ReaderScreen 改为在加载前用 CookieManager 把会话写进 WebView。
    // 已登录就带会话：自定义线路登录时密码本来就发给该线路，
    // 会话只发给同线路的 reader 子域，不再按内置/自定义区分。
    // 未登录时 user 为 null，仍不带会话，站点会弹登录墙。
    //
    // readOnlineUrl comes from the server: only attach the session when the
    // rewritten URL really points at this line's reader (https, own domain).
    // Otherwise open it without a session (the site shows its login wall).
    final trusted = isTrustedReaderUrl(url, customDomain);
    final userKey = (trusted && user?.remixUserkey.isNotEmpty == true)
        ? user!.remixUserkey
        : null;
    AppRoutes.openReader(
      context,
      ReaderArgs(
        url: url,
        title: book.title,
        remixUserId: userKey == null ? null : user?.id,
        remixUserKey: userKey,
      ),
    );
  }

  void _handleDownload(BuildContext context, WidgetRef ref) async {
    // Check for force update block
    if (ref.read(updateProvider).isBlocked && !isCompleted) {
      unawaited(showUpdateDialog(context));
      return;
    }

    if (isCompleted && downloadTask?.filePath != null) {
      await _openDownloadedFile(context, downloadTask!.filePath!);
    } else {
      // Check if file already exists
      final existingPath = await ref
          .read(downloadProvider.notifier)
          .checkFileExists(book);

      if (existingPath != null && context.mounted) {
        unawaited(
          AwesomeDialog(
            context: context,
            dialogType: DialogType.info,
            animType: AnimType.bottomSlide,
            title: AppLocalizations.of(context)!.fileExistsTitle,
            desc: AppLocalizations.of(context)!.fileExistsDesc,
            btnCancelText: AppLocalizations.of(context)!.openFile,
            btnCancelColor: Theme.of(context).colorScheme.primary,
            btnCancelOnPress: () async {
              // The dialog outlives this bar: re-check before using context.
              if (!context.mounted) return;
              await _openDownloadedFile(context, existingPath);
            },
            btnOkText: AppLocalizations.of(context)!.downloadAgain,
            btnOkColor: Theme.of(context).colorScheme.primary,
            btnOkOnPress: () {
              if (!context.mounted) return;
              _kickoffDownload(context, ref);
            },
          ).show(),
        );
        return;
      }

      if (!context.mounted) return;
      await _kickoffDownload(context, ref);
    }
  }

  /// 真正触发下载的统一入口：只走用户自己的 z站 账号。
  Future<void> _kickoffDownload(BuildContext context, WidgetRef ref) async {
    final downloadingMsg = AppLocalizations.of(context)!.downloading;
    final notifier = ref.read(downloadProvider.notifier);

    if (await _ownQuotaExhausted(ref)) {
      if (context.mounted) showDownloadQuotaDialog(context);
      return;
    }
    if (!context.mounted) return;
    // 下载结束后刷新资料，保持本地剩余次数准确
    final auth = ref.read(authProvider.notifier);
    unawaited(notifier.startDownload(book).whenComplete(auth.refreshProfile));
    _toast(context, downloadingMsg);
  }

  /// 本地缓存显示用户自己 Z 站账号额度已用尽时，刷新资料再确认一次
  /// （额度按天重置，缓存可能过期）。额度未知（null）时绝不视为用尽。
  Future<bool> _ownQuotaExhausted(WidgetRef ref) async {
    final user = ref.read(authProvider).user;
    if (user == null || user.downloadsLeft == null || user.downloadsLeft! > 0) {
      return false;
    }
    await ref.read(authProvider.notifier).refreshProfile();
    final refreshed = ref.read(authProvider).user;
    return refreshed != null &&
        refreshed.downloadsLeft != null &&
        refreshed.downloadsLeft! <= 0;
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
          _toast(context, AppLocalizations.of(context)!.openFileFailed);
        }
        return;
      }
      final result = await OpenFilex.open(path);
      if (result.type != ResultType.done && context.mounted) {
        _toast(context, AppLocalizations.of(context)!.openFileFailed);
      }
    } catch (error) {
      logIgnored('book_action_bar', error);
      if (context.mounted) {
        _toast(context, AppLocalizations.of(context)!.openFileFailed);
      }
    }
  }

  void _toast(BuildContext context, String message) {
    showAppSnack(context, message);
  }
}
