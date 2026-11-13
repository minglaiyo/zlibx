import 'package:flutter/material.dart';
import '../../../theme/app_metrics.dart';

/// Flat, bordered card used as the visual container for every settings group.
/// Overrides the app's default Card style (elevation + horizontal margin) so
/// the settings page can control its own spacing and look uniformly flat.
class SettingsCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;

  const SettingsCard({
    super.key,
    required this.child,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: cs.surface,
      borderRadius: AppRadius.sheet,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: AppRadius.sheet,
          border: Border.all(color: cs.outlineVariant, width: 1),
        ),
        padding: padding,
        child: ClipRRect(
          borderRadius: AppRadius.sheet,
          child: child,
        ),
      ),
    );
  }
}

/// Hair-line divider designed to slot between ListTiles in a SettingsCard.
/// Indents past the leading icon so the divider lines up with the title text.
class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Divider(
      height: 1,
      thickness: 1,
      indent: 56,
      endIndent: 0,
      color: cs.outlineVariant,
    );
  }
}
