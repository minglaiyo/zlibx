import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/settings_provider.dart';
import '../../../utils/locale_utils.dart' as locale_utils;
import 'section_header.dart';
import 'settings_card.dart';

class LanguageSection extends ConsumerWidget {
  const LanguageSection({super.key});

  /// Native names only: legado's language menu has no flags or English gloss.
  static const allLanguages = {
    'en': 'English',
    'zh': '简体中文',
    'zh_Hant': '繁體中文',
    'ja': '日本語',
    'ko': '한국어',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final locale = ref.watch(localeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(icon: Icons.translate_rounded, title: t.languageSetting),
        SettingsCard(
          child: Builder(
            builder: (rowContext) => ListTile(
              leading: const Icon(Icons.language_rounded),
              title: Text(t.languageSetting),
              subtitle: Text(_displayName(t, locale)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showLanguageMenu(rowContext, ref),
            ),
          ),
        ),
      ],
    );
  }

  String _displayName(AppLocalizations t, Locale? locale) {
    if (locale == null) return t.system;
    final key = locale_utils.getLocaleKey(locale);
    if (key == null) return '';
    return allLanguages[key] ?? key;
  }

  Future<void> _showLanguageMenu(BuildContext context, WidgetRef ref) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;

    final currentLocale = ref.read(localeProvider);
    final currentKey = currentLocale != null
        ? locale_utils.getLocaleKey(currentLocale)
        : null;
    final t = AppLocalizations.of(context)!;

    final anchor = Rect.fromLTWH(
      (box.size.width - 216).clamp(0.0, box.size.width),
      0,
      box.size.width.clamp(0.0, 216.0),
      box.size.height,
    );
    final global = MatrixUtils.transformRect(
      box.getTransformTo(overlay),
      anchor,
    );

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(global, Offset.zero & overlay.size),
      color: Theme.of(context).colorScheme.surfaceContainer,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 220),
      popUpAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 150),
        reverseDuration: Duration(milliseconds: 100),
      ),
      items: <PopupMenuEntry<String>>[
        _languageItem(context, 'system', t.system, currentKey == null),
        for (final entry in allLanguages.entries)
          _languageItem(
            context,
            entry.key,
            entry.value,
            currentKey == entry.key,
          ),
      ],
    );

    if (!context.mounted || selected == null) return;
    if (selected == 'system') {
      await ref.read(localeProvider.notifier).setLocale(null);
    } else {
      await ref
          .read(localeProvider.notifier)
          .setLocale(locale_utils.parseLocaleKey(selected));
    }
  }

  PopupMenuItem<String> _languageItem(
    BuildContext context,
    String value,
    String label,
    bool selected,
  ) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuItem<String>(
      value: value,
      height: 44,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? cs.primary : cs.onSurface,
              ),
            ),
          ),
          if (selected) Icon(Icons.check_rounded, size: 18, color: cs.primary),
        ],
      ),
    );
  }
}
