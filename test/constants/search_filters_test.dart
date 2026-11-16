import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/constants/search_filters.dart';

// Search sort-order vocabulary tests: the general (eapi) search
// offers the site's full sort vocabulary with both directions
// (Issue #8's sort request: file-size sort + the web version's
// ascending/descending capability), and every key carries a
// localized display name in all three shipped locales.

void main() {
  group('searchOrders vocabulary', () {
    test("offers the site's full sort vocabulary with both directions", () {
      expect(
        searchOrders.keys,
        containsAll(const [
          'default',
          'popular',
          'bestmatch',
          'titleA',
          'title',
          'date',
          'year',
          'filesize',
          'filesizeA',
        ]),
      );
      // Site semantics, do not swap: `titleA` is A–Z and `title` is
      // Z–A, `filesize` is biggest-first and `filesizeA`
      // smallest-first (verified against the live eapi).
      expect(searchOrders['titleA'], 'titleA');
      expect(searchOrders['title'], 'title');
      expect(searchOrders['filesize'], 'filesize');
      expect(searchOrders['filesizeA'], 'filesizeA');
      // The default order sends nothing to the API.
      expect(searchOrders['default'], isNull);
    });
  });

  group('getOrderDisplayNames parity', () {
    for (final locale in const ['zh_Hant', 'zh', 'en']) {
      test('$locale covers every searchOrders key', () {
        final names = getOrderDisplayNames(locale);
        for (final key in searchOrders.keys) {
          expect(
            names.containsKey(key),
            isTrue,
            reason: 'missing display name for "$key" in $locale',
          );
          expect(names[key], isNotEmpty);
        }
      });
    }
  });
}
