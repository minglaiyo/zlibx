// Verifies that the app's shared locale resolution (O11) maps device
// locales zh-TW / zh-HK / zh-MO to Traditional Chinese.
//
// Background (assessment §3 R1): the zh_TW / zh_HK / zh_MO ARB files were
// removed (they were byte-copies of zh_Hant apart from @@locale), so the
// generated delegate's supportedLocales no longer carries separate
// TW/HK/MO entries. The app resolves them to zh_Hant through
// `resolveAppLocale` (lib/l10n/locale_resolution.dart), wired as
// MaterialApp's `localeListResolutionCallback` in main.dart. This test
// drives that exact callback so a Traditional user on TW/HK/MO still
// gets the Traditional strings instead of silently falling back to
// Simplified.
//
// 'settings' is used as the probe because its zh value ('设置') and
// zh_Hant value ('設定') differ; 'cancel' would not discriminate
// (identical in both).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart' as gen;
import 'package:zlibx/l10n/locale_resolution.dart';

void main() {
  group('app locale resolution resolves Traditional Chinese', () {
    for (final country in <String>['TW', 'HK', 'MO']) {
      testWidgets('zh-$country resolves to Traditional', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale('zh', country),
            supportedLocales: gen.AppLocalizations.supportedLocales,
            // The same callback the real app uses (main.dart): maps
            // zh-TW/HK/MO to zh_Hant now that the region ARBs are gone.
            localeListResolutionCallback: resolveAppLocale,
            // The generated list (app delegate + GlobalMaterial/Cupertino/
            // Widgets). Passing only the app delegate makes MaterialApp fall
            // back to the English-only Default delegates, which fail the
            // debug locale check for any non-English locale.
            localizationsDelegates: gen.AppLocalizations.localizationsDelegates,
            home: Builder(
              builder: (context) =>
                  Text(gen.AppLocalizations.of(context)!.settings),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('設定'), findsOneWidget);
      });
    }
  });
}
