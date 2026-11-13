import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/update_dialog.dart';
import '../../l10n/generated/app_localizations.dart';
import '../auth/login_screen.dart';
import 'widgets/download_path_section.dart';
import 'widgets/donation_key_section.dart';
import 'widgets/about_section.dart';
import 'widgets/language_section.dart';
import 'widgets/theme_section.dart';
import 'widgets/network_section.dart';
import 'widgets/section_header.dart';
import 'widgets/settings_card.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final user = authState.user;
    final t = AppLocalizations.of(context)!;

    // No top bar: this is a bottom-nav tab, like the account page —
    // the title bar only eats vertical space.
    // Material instead of a nested Scaffold: this page sits under the
    // home Scaffold (extendBody: true) and must paint exactly like the
    // recommendation tab, which has no inner Scaffold.
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        top: true,
        // No bottom inset: the list already reserves the floating nav
        // bar's height (128dp bottom padding), and extendBody rewrites
        // the MediaQuery bottom padding to that same height, so a
        // bottom SafeArea would count it twice and leave a dead band
        // of scaffold background above the pill. (AccountScreen
        // already does this.)
        bottom: false,
        child: ListView(
          // Bottom 128 = 32 gap + 96 floating-nav clearance, reserved
          // inside the list (like the home grid) so items scroll
          // behind the pill instead of stopping at a blank band.
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 128),
          children: [
          // Signed in: the profile card lives on the account page now.
          // Signed out (e.g. skipped login): offer the login screen
          // here — otherwise there is no in-app way back to login.
          if (user == null)
            SettingsCard(
              child: ListTile(
                leading: const Icon(Icons.login),
                title: Text(t.login),
                subtitle: Text(t.loginToContinue),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => const LoginScreen(),
                  ),
                ),
              ),
            ),
          if (user == null) const SizedBox(height: 24),

          const DownloadPathSection(),
          const DonationKeySection(),

          const SizedBox(height: 20),

          // ── Network ─────────────────────────────────────────────
          const NetworkSection(),

          const SizedBox(height: 20),

          // ── Theme ────────────────────────────────────────────────
          const ThemeSection(),

          const SizedBox(height: 20),

          // ── Update ───────────────────────────────────────────────
          SectionHeader(
            icon: Icons.system_update_rounded,
            title: AppLocalizations.of(context)!.update,
          ),
          SettingsCard(
            child: ListTile(
              leading: const Icon(Icons.system_update),
              title: Text(AppLocalizations.of(context)!.checkForUpdates),
              subtitle: FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snapshot) {
                  final version = snapshot.data?.version ?? '...';
                  return Text(
                    AppLocalizations.of(context)!.currentVersionLabel(version),
                  );
                },
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showManualUpdateCheck(context),
            ),
          ),

          const SizedBox(height: 20),

          // ── Language ─────────────────────────────────────────────
          const LanguageSection(),

          const SizedBox(height: 20),

          // ── About ────────────────────────────────────────────────
          const AboutSection(),
          ],
        ),
      ),
    );
  }
}
