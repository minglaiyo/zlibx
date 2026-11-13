import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/generated/app_localizations.dart';
import '../providers/update_provider.dart';
import '../routes/app_routes.dart';
import '../utils/app_log.dart';
import '../utils/app_snack.dart';
import 'loading_widget.dart';

/// 更新对话框：Release 清单里的下载渠道（网盘等）+ 官网 + GitHub，用户自选。
///
/// 强制更新时不可关闭（返回键 / 点遮罩均无效）。
Future<void> showUpdateDialog(BuildContext context) {
  final forced =
      ProviderScope.containerOf(context).read(updateProvider).forceUpdate;
  return showDialog<void>(
    context: context,
    barrierDismissible: !forced,
    builder: (_) => PopScope(canPop: !forced, child: const _UpdateDialog()),
  );
}

/// 设置页「检查更新」：强制请求一次，有新版本弹更新对话框，否则提示已是最新
Future<void> showManualUpdateCheck(BuildContext context) async {
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: Row(
        children: [
          const LoadingWidget.inline(),
          const SizedBox(width: 20),
          Text(AppLocalizations.of(context)!.checkingUpdates),
        ],
      ),
    ),
  ));

  final hasUpdate = await ProviderScope.containerOf(context)
      .read(updateProvider.notifier)
      .checkForUpdate(force: true);
  if (!context.mounted) return;
  Navigator.of(context).pop();

  if (hasUpdate) {
    await showUpdateDialog(context);
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(AppLocalizations.of(context)!.upToDateTitle),
      content: Text(AppLocalizations.of(context)!.upToDateDesc),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(AppLocalizations.of(context)!.gotIt),
        ),
      ],
    ),
  );
}

/// 强制更新对话框里的逃生口：先关对话框，再打开指定页面。
/// NavigatorState 先取出来再 pop —— pop 掉的 dialog context 不能再用来 push。
void _openEscapePage(BuildContext context, String route) {
  final navigator = Navigator.of(context);
  navigator.pop();
  navigator.pushNamed(route);
}

class _Channel {
  final String name;
  final String url;
  final IconData icon;

  const _Channel(this.name, this.url, this.icon);
}

class _UpdateDialog extends ConsumerWidget {
  const _UpdateDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(updateProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final forced = update.forceUpdate;
    final notes = update.getChangelog(isZh ? 'zh' : 'en');

    final channels = [
      for (final l in update.links)
        // Show the real host next to the label so a spoofed name cannot
        // hide where the button goes.
        _Channel(
          '${l.name} (${Uri.tryParse(l.url)?.host ?? ''})',
          l.url,
          Icons.cloud_download_outlined,
        ),
      if (update.downloadUrl != null)
        _Channel(
          AppLocalizations.of(context)!.websiteDownload,
          update.downloadUrl!,
          Icons.language,
        ),
      if (update.releaseUrl != null)
        _Channel('GitHub', update.releaseUrl!, Icons.code),
    ];

    return AlertDialog(
      icon: Icon(Icons.system_update, color: cs.primary, size: 32),
      title: Text(
        forced
            ? (AppLocalizations.of(context)!.updateRequired)
            : (AppLocalizations.of(context)!.updateFoundTitle(update.latestVersion ?? '')),
        textAlign: TextAlign.center,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AppLocalizations.of(context)!.updateCurrentLatest(update.currentVersion ?? '', update.latestVersion ?? ''),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              if (forced) ...[
                const SizedBox(height: 12),
                Text(
                  AppLocalizations.of(context)!.updateUnsupported,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 180),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      notes,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        height: 1.6,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                AppLocalizations.of(context)!.chooseDownloadSource,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < channels.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                _ChannelButton(channel: channels[i], primary: i == 0),
              ],
              if (update.droppedLinkCount > 0) ...[
                const SizedBox(height: 12),
                Text(
                  AppLocalizations.of(context)!.updateDroppedLinks(update.droppedLinkCount),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (!forced)
          TextButton(
            onPressed: () {
              ref.read(updateProvider.notifier).dismissUpdate();
              Navigator.of(context).pop();
            },
            child: Text(AppLocalizations.of(context)!.later),
          ),
        if (forced) ...[
          // 强制更新的逃生口：这是一把远程熔断开关（仓库/账号被入侵时
          // 阻止旧版继续用），不是要把用户锁在应用外。已下载的书和
          // 设置页始终可达；搜索与新下载仍被 isBlocked 拦截，冷启动
          // 时对话框还会再出现。
          TextButton(
            onPressed: () => _openEscapePage(context, AppRoutes.downloads),
            child: Text(AppLocalizations.of(context)!.shelfDownloaded),
          ),
          TextButton(
            onPressed: () => _openEscapePage(context, AppRoutes.settings),
            child: Text(AppLocalizations.of(context)!.settings),
          ),
        ],
      ],
    );
  }
}

class _ChannelButton extends StatelessWidget {
  final _Channel channel;
  final bool primary;

  const _ChannelButton({required this.channel, required this.primary});

  Future<void> _open(BuildContext context) async {
    var ok = false;
    try {
      ok = await launchUrl(
        Uri.parse(channel.url),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      // The exception text can repeat the URL: log the type only.
      // The channel URL itself stays: the dialog shows it to the user
      // to copy by hand, so it is user-visible by design.
      AppLog.report(
        'UpdateDialog: failed to open ${channel.url}: ${e.runtimeType}',
        tag: 'update_dialog',
      );
    }
    // 打不开时把链接显示出来，方便用户手动复制
    if (!ok && context.mounted) {
      // SelectableText 让链接可长按复制，保留原生内容。
      showAppSnackRaw(
        context,
        SnackBar(
          content: SelectableText(channel.url),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = Row(
      children: [
        Icon(channel.icon, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(channel.name)),
        const Icon(Icons.open_in_new, size: 16),
      ],
    );
    return primary
        ? FilledButton(onPressed: () => _open(context), child: child)
        : OutlinedButton(onPressed: () => _open(context), child: child);
  }
}
