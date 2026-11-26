import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/utils/isbn.dart';

// ISBN tool tests (plan item 7): Dart port of qgming/zlib-app's
// Isbn.kt. The known pair 9780306406157 <-> 0306406152 anchors the
// conversions; the X-check-digit case is asserted as a round-trip so
// the test does not depend on a hand-computed check digit.

void main() {
  group('normalizeIsbn', () {
    test('strips separators and uppercases', () {
      expect(normalizeIsbn('978-0-306-40615-7'), '9780306406157');
      expect(normalizeIsbn('0 8044 2957 x'), '080442957X');
      expect(normalizeIsbn('978–0–306–40615–7'), '9780306406157');
      expect(normalizeIsbn('978—0—306—40615—7'), '9780306406157');
    });
  });

  group('isValidIsbn10', () {
    test('accepts valid ISBN-10s with and without separators', () {
      expect(isValidIsbn10('0306406152'), isTrue);
      expect(isValidIsbn10('0-306-40615-2'), isTrue);
      expect(isValidIsbn10('080442957X'), isTrue);
      expect(isValidIsbn10('0-8044-2957-X'), isTrue);
    });

    test('rejects a bad check digit and non-ISBN input', () {
      expect(isValidIsbn10('0306406153'), isFalse);
      expect(isValidIsbn10('9780306406157'), isFalse);
      expect(isValidIsbn10('030640615'), isFalse);
      expect(isValidIsbn10('helloworld'), isFalse);
    });
  });

  group('isValidIsbn13', () {
    test('accepts valid ISBN-13s with and without separators', () {
      expect(isValidIsbn13('9780306406157'), isTrue);
      expect(isValidIsbn13('978-0-306-40615-7'), isTrue);
    });

    test('rejects a bad check digit and wrong lengths', () {
      expect(isValidIsbn13('9780306406158'), isFalse);
      expect(isValidIsbn13('978030640615'), isFalse);
      expect(isValidIsbn13('97803064061577'), isFalse);
    });
  });

  group('conversions', () {
    test('978 ISBN-13 converts to ISBN-10 and back', () {
      expect(isbn13ToIsbn10('9780306406157'), '0306406152');
      expect(isbn10ToIsbn13('0306406152'), '9780306406157');
      expect(isbn10ToIsbn13('0-306-40615-2'), '9780306406157');
    });

    test('a 979 ISBN-13 has no ISBN-10', () {
      // 9791090636071 is a valid ISBN-13 (979 prefix).
      expect(isbn13ToIsbn10('9791090636071'), isNull);
    });

    test('an X check digit survives the round-trip', () {
      final isbn13 = isbn10ToIsbn13('080442957X');
      expect(isbn13, isNotNull);
      expect(isbn13ToIsbn10(isbn13!), '080442957X');
    });

    test('invalid input converts to null', () {
      expect(isbn13ToIsbn10('9780306406158'), isNull);
      expect(isbn10ToIsbn13('0306406153'), isNull);
      expect(isbn13ToIsbn10('not-an-isbn'), isNull);
    });
  });

  group('canonicalIsbnForSearch', () {
    test('ISBN-13 stays, ISBN-10 becomes its 978 ISBN-13', () {
      expect(canonicalIsbnForSearch('978-0-306-40615-7'), '9780306406157');
      expect(canonicalIsbnForSearch('0306406152'), '9780306406157');
      expect(canonicalIsbnForSearch('garbage'), isNull);
    });
  });

  group('extractIsbns', () {
    test('splits on , ; | newline /, validates, dedups, drops ASINs', () {
      final found = extractIsbns(
        '978-0-306-40615-7, 0306406152; B012345678 | 9780306406157\n'
        '080442957X / garbage',
      );
      expect(found, hasLength(2));
      expect(found.first, '9780306406157');
      expect(found.last, isbn10ToIsbn13('080442957X'));
    });

    test('an ASIN alone yields nothing', () {
      expect(extractIsbns('B012345678'), isEmpty);
      expect(extractIsbns(''), isEmpty);
    });
  });

  group('normalizeIsbnQuery', () {
    test('a bare ISBN becomes its canonical ISBN-13 digits', () {
      expect(normalizeIsbnQuery('978-0-306-40615-7'), '9780306406157');
      expect(normalizeIsbnQuery('0306406152'), '9780306406157');
      expect(normalizeIsbnQuery(' 9780306406157 '), '9780306406157');
    });

    test('anything else passes through unchanged', () {
      expect(normalizeIsbnQuery('harry potter'), 'harry potter');
      expect(normalizeIsbnQuery(''), '');
    });
  });
}
