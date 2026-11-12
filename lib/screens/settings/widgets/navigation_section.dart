import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/nav_label_mode.dart';
import '../../../providers/settings_provider.dart';
import 'section_header.dart';
import 'settings_card.dart';

/// First-level navigation/bar settings: blur, refraction, floating,
/// hide-on-scroll and label mode. The appearance sheet now keeps only the
/// theme choice.
class NavigationSection extends ConsumerWidget {
  const NavigationSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final t = AppLocalizations.of(context)!;
    final blurEnabled = ref.watch(blurEnabledProvider);
    final refraction = ref.watch(glassRefractionProvider);
    final floatingNav = ref.watch(floatingNavProvider);
    final hideNavOnScroll = ref.watch(hideNavOnScrollProvider);
    final labelMode = ref.watch(navLabelModeProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(icon: Icons.navigation_rounded, title: t.navigation),
        SettingsCard(
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.blur_on_rounded),
                title: Text(t.blurEffect),
                value: blurEnabled,
                activeThumbColor: cs.primary,
                onChanged: (value) {
                  ref.read(blurEnabledProvider.notifier).setBlurEnabled(value);
                },
              ),
              const SettingsDivider(),
              SwitchListTile(
                secondary: const Icon(Icons.water_drop_outlined),
                title: Text(t.glassRefraction),
                subtitle: Text(t.glassRefractionDesc),
                value: blurEnabled && refraction,
                activeThumbColor: cs.primary,
                onChanged: blurEnabled
                    ? (value) {
                        ref
                            .read(glassRefractionProvider.notifier)
                            .setGlassRefraction(value);
                      }
                    : null,
              ),
              const SettingsDivider(),
              SwitchListTile(
                secondary: const Icon(Icons.picture_in_picture_alt_outlined),
                title: Text(t.floatingNav),
                value: floatingNav,
                activeThumbColor: cs.primary,
                onChanged: (value) {
                  ref.read(floatingNavProvider.notifier).setFloatingNav(value);
                },
              ),
              const SettingsDivider(),
              SwitchListTile(
                secondary: const Icon(Icons.vertical_align_bottom_rounded),
                title: Text(t.hideNavOnScroll),
                value: hideNavOnScroll,
                activeThumbColor: cs.primary,
                onChanged: floatingNav
                    ? (value) {
                        ref
                            .read(hideNavOnScrollProvider.notifier)
                            .setHideNavOnScroll(value);
                      }
                    : null,
              ),
              const SettingsDivider(),
              Builder(
                builder: (rowContext) => ListTile(
                  leading: const Icon(Icons.text_fields_rounded),
                  title: Text(t.navLabelMode),
                  subtitle: Text(_labelText(t, labelMode)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showLabelMenu(rowContext, ref, labelMode),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _labelText(AppLocalizations t, NavLabelMode mode) {
    return switch (mode) {
      NavLabelMode.always => t.navLabelAlways,
      NavLabelMode.auto => t.navLabelAuto,
      NavLabelMode.never => t.navLabelNever,
    };
  }

  Future<void> _showLabelMenu(
    BuildContext context,
    WidgetRef ref,
    NavLabelMode current,
  ) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;

    final anchor = Rect.fromLTWH(
      (box.size.width - 180).clamp(0.0, box.size.width),
      0,
      box.size.width.clamp(0.0, 180.0),
      box.size.height,
    );
    final global = MatrixUtils.transformRect(
      box.getTransformTo(overlay),
      anchor,
    );
    final t = AppLocalizations.of(context)!;

    final selected = await showMenu<NavLabelMode>(
      context: context,
      position: RelativeRect.fromRect(global, Offset.zero & overlay.size),
      color: Theme.of(context).colorScheme.surfaceContainer,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      constraints: const BoxConstraints(minWidth: 160, maxWidth: 200),
      popUpAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 150),
        reverseDuration: Duration(milliseconds: 100),
      ),
      items: <PopupMenuEntry<NavLabelMode>>[
        for (final mode in NavLabelMode.values)
          PopupMenuItem<NavLabelMode>(
            value: mode,
            height: 44,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _labelText(t, mode),
                    style: TextStyle(
                      fontWeight: mode == current
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (mode == current)
                  Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
              ],
            ),
          ),
      ],
    );

    if (!context.mounted || selected == null) return;
    await ref.read(navLabelModeProvider.notifier).setMode(selected);
  }
}
