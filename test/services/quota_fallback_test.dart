// Quota-fallback best-match scoring tests (pure function, no network):
// the score decides which external result is the same book, and whether
// a title search matched at all (threshold 100: exact title, or partial
// title + exact author). An ISBN search is exact by construction and
// bypasses the threshold in the caller, so it is not scored here.

import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/annas_models.dart';
import 'package:zlibx/services/quota_fallback.dart';

BookData _candidate({
  required String title,
  String? author,
  String? info,
}) => BookData(
  title: title,
  author: author,
  link: '/md5/0123456789abcdef0123456789abcdef',
  md5: '0123456789abcdef0123456789abcdef',
  info: info,
);

void main() {
  group('quotaFallbackMatchScore', () {
    test('exact title + author + format scores 150', () {
      expect(
        quotaFallbackMatchScore(
          _candidate(
            title: 'Dune',
            author: 'Frank Herbert',
            info: 'English, EPUB, 1 MB, 1965',
          ),
          title: 'Dune',
          author: 'Frank Herbert',
          extension: 'epub',
        ),
        150,
      );
    });

    test('exact title alone meets the threshold', () {
      expect(
        quotaFallbackMatchScore(
          _candidate(title: 'Dune', author: 'Someone Else'),
          title: 'Dune',
          author: 'Frank Herbert',
        ),
        100,
      );
    });

    test('partial title + exact author meets the threshold', () {
      expect(
        quotaFallbackMatchScore(
          _candidate(title: 'Dune Messiah', author: 'Frank Herbert'),
          title: 'Dune',
          author: 'Frank Herbert',
        ),
        100,
      );
    });

    test('partial title without the author is below the threshold', () {
      expect(
        quotaFallbackMatchScore(
          _candidate(title: 'Dune Messiah', author: 'Brian Herbert'),
          title: 'Dune',
          author: 'Frank Herbert',
        ),
        60,
      );
    });

    test('an unrelated book scores 0', () {
      expect(
        quotaFallbackMatchScore(
          _candidate(title: 'Foundation', author: 'Isaac Asimov'),
          title: 'Dune',
          author: 'Frank Herbert',
        ),
        0,
      );
    });

    test('punctuation and case do not matter', () {
      expect(
        quotaFallbackMatchScore(
          _candidate(title: 'Dune: Part One', author: 'FRANK HERBERT'),
          title: 'dune part one',
          author: 'Frank Herbert',
        ),
        140,
      );
    });

    test('a different format loses only the format bonus', () {
      expect(
        quotaFallbackMatchScore(
          _candidate(
            title: 'Dune',
            author: 'Frank Herbert',
            info: 'English, PDF, 5 MB, 1965',
          ),
          title: 'Dune',
          author: 'Frank Herbert',
          extension: 'epub',
        ),
        140,
      );
    });
  });
}
