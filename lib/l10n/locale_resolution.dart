// Locale resolution for the app (O11).
//
// The zh_TW / zh_HK / zh_MO ARB files were removed: they were
// byte-identical to `app_zh_Hant.arb` apart from the `@@locale` line,
// so the generated delegate no longer carries separate TW/HK/MO
// tables. This callback maps those device locales to `zh_Hant` so a
// Traditional-Chinese user on Taiwan / Hong Kong / Macau still gets
// the Traditional strings instead of silently falling back to
// Simplified.
//
// Shared here (not inlined in `main.dart`) so the resolution strategy is
// testable: `test/widgets/locale_zh_hant_resolution_test.dart` drives
// the exact same callback the real app uses.
import 'dart:ui';

/// A [LocaleListResolutionCallback] that maps zh-TW / zh-HK / zh-MO to
/// `zh_Hant`. Any other locale falls through (returns null) so
/// MaterialApp applies its default resolution.
Locale? resolveAppLocale(
  Iterable<Locale>? locales,
  Iterable<Locale>? supportedLocales,
) {
  final candidates = locales?.toList() ?? const <Locale>[];
  for (final l in candidates) {
    final lang = l.languageCode;
    final cc = l.countryCode;
    if (lang == 'zh' && (cc == 'TW' || cc == 'HK' || cc == 'MO')) {
      return Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
    }
  }
  return null;
}
