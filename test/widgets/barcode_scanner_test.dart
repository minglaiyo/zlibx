// ISBN barcode check tests (pure function, no camera): a book barcode
// is a 13-digit EAN starting with 978/979 — the 13 digits are the
// ISBN-13. Anything else is not a book barcode.

import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/screens/search/barcode_scanner_screen.dart';

void main() {
  group('isBookBarcode', () {
    test('accepts a 978 ISBN-13', () {
      expect(isBookBarcode('9783161484100'), isTrue);
    });

    test('accepts a 979 ISBN-13', () {
      expect(isBookBarcode('9791090636071'), isTrue);
    });

    test('trims surrounding whitespace', () {
      expect(isBookBarcode(' 9783161484100 '), isTrue);
    });

    test('rejects a 12-digit code', () {
      expect(isBookBarcode('978316148410'), isFalse);
    });

    test('rejects a 14-digit code', () {
      expect(isBookBarcode('97831614841000'), isFalse);
    });

    test('rejects a non-book EAN prefix', () {
      expect(isBookBarcode('9773161484100'), isFalse);
    });

    test('rejects non-digit characters', () {
      expect(isBookBarcode('978316148410A'), isFalse);
    });

    test('rejects an empty string', () {
      expect(isBookBarcode(''), isFalse);
    });
  });
}
