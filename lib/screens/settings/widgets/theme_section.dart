import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/settings_provider.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'section_header.dart';
import 'settings_card.dart';

/// Appearance entry — same chevron-tile shape as the other settings.
/// Tapping it opens the appearance popup (same AlertDialog style as the
/// network-line picker); the row's subtitle summarises the current
/// theme, blur and floating-bar state.
class ThemeSection extends ConsumerWidget {
  const ThemeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final blurEnabled = ref.watch(blurEnabledProvider);
    final floatingNav = ref.watch(floatingNavProvider);
    final t = AppLocalizations.of(context)!;

    final summary = <String>[
      switch (themeMode) {
        AppThemeMode.system => t.system,
        AppThemeMode.dark => t.dark,
        AppThemeMode.light => t.light,
      },
      if (blurEnabled) t.blurEffect,
      if (floatingNav) t.floatingNav,
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          icon: Icons.palette_rounded,
          title: t.appearance,
        ),
        SettingsCard(
          child: ListTile(
            leading: const Icon(Icons.palette_rounded),
            title: Text(t.appearance),
            subtitle: Text(summary),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              builder: (_) => const AppearanceSheet(),
            ),
          ),
        ),
      ],
    );
  }
}

/// Appearance bottom sheet — the five switches (follow system, dark mode,
/// blur effect, floating bar, hide on scroll), in the same bottom-sheet
/// style as the language picker (drag handle, centred bold title,
/// divider). Dismiss by dragging down or tapping outside; no Close button.
class AppearanceSheet extends ConsumerWidget {
  const AppearanceSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final blurEnabled = ref.watch(blurEnabledProvider);
    final floatingNav = ref.watch(floatingNavProvider);
    final hideNavOnScroll = ref.watch(hideNavOnScrollProvider);
    final t = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final followingSystem = themeMode == AppThemeMode.system;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Handle bar
        Container(
          margin: const EdgeInsets.only(top: 12),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            t.appearance,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ),
        const Divider(height: 1),
        SwitchListTile(
          title: Text(t.system),
          value: followingSystem,
          activeThumbColor: cs.primary,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          onChanged: (value) {
            ref.read(themeModeProvider.notifier).setThemeMode(
                  value ? AppThemeMode.system : AppThemeMode.light,
                );
          },
        ),
        SwitchListTile(
          title: Text(t.darkMode),
          value: themeMode == AppThemeMode.dark,
          activeThumbColor: cs.primary,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          onChanged: followingSystem
              ? null
              : (value) {
                  ref.read(themeModeProvider.notifier).setThemeMode(
                        value ? AppThemeMode.dark : AppThemeMode.light,
                      );
                },
        ),
        SwitchListTile(
          title: Text(t.blurEffect),
          value: blurEnabled,
          activeThumbColor: cs.primary,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          onChanged: (value) {
            ref.read(blurEnabledProvider.notifier).setBlurEnabled(value);
          },
        ),
        SwitchListTile(
          title: Text(t.floatingNav),
          value: floatingNav,
          activeThumbColor: cs.primary,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          onChanged: (value) {
            ref.read(floatingNavProvider.notifier).setFloatingNav(value);
          },
        ),
        SwitchListTile(
          title: Text(t.hideNavOnScroll),
          value: hideNavOnScroll,
          activeThumbColor: cs.primary,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          onChanged: floatingNav
              ? (value) {
                  ref
                      .read(hideNavOnScrollProvider.notifier)
                      .setHideNavOnScroll(value);
                }
              : null,
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
