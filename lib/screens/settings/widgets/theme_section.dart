import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/settings_provider.dart';
import 'section_header.dart';
import 'settings_card.dart';

/// Appearance entry: just the three-way theme choice, opened as a small
/// right-side popup (same interaction as the language row). Blur, refraction,
/// floating bar and nav labels live in the first-level Navigation section.
class ThemeSection extends ConsumerWidget {
  const ThemeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final t = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(icon: Icons.palette_rounded, title: t.appearance),
        SettingsCard(
          child: Builder(
            builder: (rowContext) => ListTile(
              leading: const Icon(Icons.palette_rounded),
              title: Text(t.appearance),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showThemeMenu(rowContext, ref, themeMode),
            ),
          ),
        ),
      ],
    );
  }

  String _currentLabel(AppLocalizations t, AppThemeMode mode) {
    return switch (mode) {
      AppThemeMode.system => t.system,
      AppThemeMode.light => t.light,
      AppThemeMode.dark => t.dark,
    };
  }

  Future<void> _showThemeMenu(
    BuildContext context,
    WidgetRef ref,
    AppThemeMode current,
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

    final selected = await showMenu<AppThemeMode>(
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
      items: <PopupMenuEntry<AppThemeMode>>[
        for (final mode in AppThemeMode.values)
          PopupMenuItem<AppThemeMode>(
            value: mode,
            height: 44,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _currentLabel(t, mode),
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
    await ref.read(themeModeProvider.notifier).setThemeMode(selected);
  }
}
