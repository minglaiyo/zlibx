import 'dart:async';
import 'package:flutter/material.dart';
import '../../../theme/app_metrics.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'section_header.dart';
import 'settings_card.dart';

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
                title: Text(
                    AppLocalizations.of(context)!.aboutZlibrary),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showAboutApp(context),
              ),
              const SettingsDivider(),
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title:
                    Text(AppLocalizations.of(context)!.openSourceLicenses),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'zlibx',
                ),
              ),
              const SettingsDivider(),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(AppLocalizations.of(context)!.version),
                trailing: FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (context, snapshot) {
                    final version = snapshot.data?.version ?? '...';
                    return Text(version);
                  },
                ),
              ),
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

    unawaited(showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: AppRadius.sheet),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.1),
                borderRadius: AppRadius.thumb,
              ),
              child: Icon(
                Icons.auto_stories,
                color: cs.primary,
                size: 28,
              ),
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
                          'https://github.com/shiyi-0x7f/olib-mobile'),
                      icon: const Icon(Icons.code, size: 16),
                      label: Text(AppLocalizations.of(context)!.original),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _launchUrl(
                          'https://github.com/minglaiyo/zlibx'),
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
                    Icon(Icons.star,
                        color: cs.primary, size: 20),
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
    ));
  }
}
