// M6 drift guard: app_zh_TW / app_zh_HK / app_zh_MO must stay value-
// identical to app_zh_Hant (apart from `@@locale`).
//
// Why the files must exist and be full copies (reviewed 2026-11-13):
// gen-l10n resolves `zh_TW` / `zh_HK` / `zh_MO` to the SIMPLIFIED
// `AppLocalizationsZh` — its fallback never routes through
// `zh_Hant` (the generated `AppLocalizationsZhTw extends
// AppLocalizationsZh`, verified by regenerating with the region files
// removed). The region ARBs ARE the Traditional delivery for those
// locales, so they cannot be collapsed to overrides. What CAN be
// enforced is that they do not drift apart: a Traditional string fix
// must land in all four files, and this test fails loudly when one is
// missed — silently serving one region Simplified text would otherwise
// go unnoticed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final arbDir = Directory(p.join('lib', 'l10n'));
  final base = _readArb(p.join(arbDir.path, 'app_zh_Hant.arb'));
  base.remove('@@locale');

  test('app_zh_Hant.arb exists and has Traditional content', () {
    expect(base, isNotEmpty);
    expect(base['about'], '關於');
  });

  for (final region in const ['zh_TW', 'zh_HK', 'zh_MO']) {
    test('$region matches zh_Hant value-for-value', () {
      final file = File(p.join(arbDir.path, 'app_$region.arb'));
      expect(
        file.existsSync(),
        isTrue,
        reason: 'app_$region.arb was deleted: zh_$region devices would '
            'fall back to SIMPLIFIED zh (gen-l10n does not route the '
            'fallback through zh_Hant). Restore the file as a full '
            'copy of app_zh_Hant.arb with only @@locale changed.',
      );
      final map = _readArb(file.path);
      expect(map.remove('@@locale'), region);
      expect(
        map.keys.toSet(),
        base.keys.toSet(),
        reason: 'Key sets diverged between zh_Hant and $region — add '
            'the new keys to both (values are identical Traditional '
            'text; see the file comment in this test).',
      );
      for (final key in base.keys) {
        expect(
          map[key],
          base[key],
          reason: 'Value drift for "$key": fix it in all four '
              'Traditional files (zh_Hant, zh_TW, zh_HK, zh_MO) so no '
              'region silently serves different text.',
        );
      }
    });
  }
}

Map<String, dynamic> _readArb(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw StateError('$path is not a JSON object');
  }
  return decoded;
}
