import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../widgets/book_quote_slip.dart';
import '../../../theme/app_metrics.dart';
import 'section_header.dart';
import 'settings_card.dart';

/// 关于区的"版本"行：连点 5 次（2 秒窗口内）翻出一张书语诗签
/// 彩蛋。整行为点击区（行本身原先没有点击行为，互不影响），每次
/// 连点带触觉反馈。
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          icon: Icons.info_outline_rounded,
          title: AppLocalizations.of(context)!.about,
        ),
        SettingsCard(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.book_outlined),
                title: Text(AppLocalizations.of(context)!.aboutZlibrary),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showAboutApp(context),
              ),
              const SettingsDivider(),
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(AppLocalizations.of(context)!.openSourceLicenses),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    showLicensePage(context: context, applicationName: 'zlibx'),
              ),
              const SettingsDivider(),
              const _VersionRow(),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showAboutApp(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    unawaited(
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: AppRadius.sheet),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.1),
                  borderRadius: AppRadius.thumb,
                ),
                child: Icon(Icons.auto_stories, color: cs.primary, size: 28),
              ),
              const SizedBox(width: 12),
              Text(
                'zlibx',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: cs.primary,
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  AppLocalizations.of(context)!.aboutAiBuiltTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  AppLocalizations.of(context)!.aboutBody,
                  style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  AppLocalizations.of(context)!.aboutCredits,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _launchUrl(
                          'https://github.com/shiyi-0x7f/olib-mobile',
                        ),
                        icon: const Icon(Icons.code, size: 16),
                        label: Text(AppLocalizations.of(context)!.original),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () =>
                            _launchUrl('https://github.com/minglaiyo/zlibx'),
                        icon: const Icon(Icons.code, size: 16),
                        label: const Text('zlibx'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: AppRadius.thumb,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.star, color: cs.primary, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context)!.aboutQuote,
                          style: TextStyle(
                            fontStyle: FontStyle.italic,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocalizations.of(context)!.close),
            ),
          ],
        ),
      ),
    );
  }
}

class _VersionRow extends StatefulWidget {
  const _VersionRow();

  @override
  State<_VersionRow> createState() => _VersionRowState();
}

class _VersionRowState extends State<_VersionRow> {
  int _taps = 0;
  Timer? _tapWindow;

  void _onTap() {
    HapticFeedback.selectionClick();
    _taps += 1;
    _tapWindow?.cancel();
    _tapWindow = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _taps = 0);
    });
    if (_taps >= 5) {
      _tapWindow?.cancel();
      setState(() => _taps = 0);
      unawaited(showBookQuoteSlip(context));
    }
  }

  @override
  void dispose() {
    _tapWindow?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.info_outline),
      title: Text(AppLocalizations.of(context)!.version),
      onTap: _onTap,
      trailing: FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snapshot) {
          final version = snapshot.data?.version ?? '...';
          return Text(version);
        },
      ),
    );
  }
}
