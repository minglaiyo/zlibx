// O11 drift guard: the zh_TW / zh_HK / zh_MO ARB files are removed and
// their locales resolve to zh_Hant through `resolveAppLocale`.
//
// Why the files are gone (reviewed 2026-11-14): they were byte-identical
// to `app_zh_Hant.arb` apart from `@@locale`, and gen-l10n resolves
// `zh_TW` / `zh_HK` / `zh_MO` to the SIMPLIFIED `AppLocalizationsZh`
// when the region files are absent (its fallback never routes through
// `zh_Hant`). Instead of carrying three duplicate ~25 KB ARB files, the
// app maps those device locales to zh_Hant via
// `resolveAppLocale` (lib/l10n/locale_resolution.dart), wired as
// MaterialApp's `localeListResolutionCallback` in main.dart.
//
// This test guards the new invariant:
//   1. the three region ARB files are absent (the dedup is real — if
//      someone re-adds them, that's a deliberate change that must also
//      update this test);
//   2. `resolveAppLocale` returns zh_Hant for each of TW / HK / MO, so a
//      Traditional user on those regions still gets Traditional strings
//      instead of silently falling back to Simplified.
//
// `settings` is the discriminator: its zh value ('设置') and zh_Hant
// value ('設定') differ, so resolving to zh_Hant is observable.
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zlibx/l10n/locale_resolution.dart';

void main() {
  final arbDir = Directory(p.join('lib', 'l10n'));

  test('app_zh_Hant.arb exists and has Traditional content', () {
    final file = File(p.join(arbDir.path, 'app_zh_Hant.arb'));
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('設定'));
  });

  for (final region in const ['zh_TW', 'zh_HK', 'zh_MO']) {
    test('$region ARB is removed (dedup) and resolves to zh_Hant', () {
      // The region file is gone — the dedup is real.
      final file = File(p.join(arbDir.path, 'app_$region.arb'));
      expect(
        file.existsSync(),
        isFalse,
        reason: 'app_$region.arb was re-added: the O11 dedup removed it. '
            'If this is intentional, update this test to reflect the '
            'new invariant.',
      );

      // The resolution callback maps the device locale to zh_Hant, so
      // the Traditional strings (not Simplified) are served.
      final locale = Locale('zh', region.split('_').last);
      final resolved = resolveAppLocale([locale], const []);
      expect(resolved, isNotNull);
      expect(resolved!.languageCode, 'zh');
      expect(resolved.scriptCode, 'Hant');
    });
  }

  test('resolveAppLocale leaves other locales untouched', () {
    // A non-Traditional zh locale (e.g. zh-CN) and a non-zh locale
    // must fall through (null) so MaterialApp applies its default.
    expect(resolveAppLocale([Locale('zh', 'CN')], const []), isNull);
    expect(resolveAppLocale([Locale('en')], const []), isNull);
    expect(resolveAppLocale(null, const []), isNull);
  });
}
