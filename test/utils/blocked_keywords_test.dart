import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/utils/blocked_keywords.dart';

void main() {
  group('isBlockedByKeywords', () {
    test('empty blocklist never blocks', () {
      expect(
        isBlockedByKeywords(
          title: 'Dune',
          author: 'Frank Herbert',
          publisher: 'Ace',
          keywords: const [],
        ),
        isFalse,
      );
    });

    test('matches a keyword in the title', () {
      expect(
        isBlockedByKeywords(
          title: 'Dune Messiah',
          author: 'Frank Herbert',
          publisher: 'Ace',
          keywords: const ['dune'],
        ),
        isTrue,
      );
    });

    test('matches a keyword in the author', () {
      expect(
        isBlockedByKeywords(
          title: 'Dune',
          author: 'Frank Herbert',
          publisher: 'Ace',
          keywords: const ['herbert'],
        ),
        isTrue,
      );
    });

    test('matches a keyword in the publisher', () {
      expect(
        isBlockedByKeywords(
          title: 'Dune',
          author: 'Frank Herbert',
          publisher: 'Ace Books',
          keywords: const ['ace'],
        ),
        isTrue,
      );
    });

    test('matching is case-insensitive and substring-based', () {
      expect(
        isBlockedByKeywords(
          title: 'DUNE',
          author: null,
          publisher: null,
          keywords: const ['dun'],
        ),
        isTrue,
      );
    });

    test('no match when the keyword appears nowhere', () {
      expect(
        isBlockedByKeywords(
          title: 'Dune',
          author: 'Frank Herbert',
          publisher: 'Ace',
          keywords: const ['asimov'],
        ),
        isFalse,
      );
    });

    test('blank keywords never match', () {
      expect(
        isBlockedByKeywords(
          title: 'Dune',
          author: 'Frank Herbert',
          publisher: 'Ace',
          keywords: const ['  ', ''],
        ),
        isFalse,
      );
    });

    test('a book with no fields is never blocked', () {
      expect(
        isBlockedByKeywords(
          title: null,
          author: null,
          publisher: null,
          keywords: const ['dune'],
        ),
        isFalse,
      );
    });
  });
}
