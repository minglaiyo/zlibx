import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/providers/download_provider.dart';

/// H2: only a 32-char hex digest may gate the delete-on-mismatch path.
/// External-source parsers fall back to the book title or a numeric id
/// when a search row carries no md5 link; those must skip verification
/// so a good download is never deleted.
void main() {
  group('isVerifiableMd5', () {
    test('32-char lowercase hex is verifiable', () {
      expect(isVerifiableMd5('d41d8cd98f00b204e9800998ecf8427e'), isTrue);
    });

    test('32-char uppercase hex is verifiable', () {
      expect(isVerifiableMd5('D41D8CD98F00B204E9800998ECF8427E'), isTrue);
    });

    test('a book title is not verifiable', () {
      expect(isVerifiableMd5('资本论（全三卷）'), isFalse);
    });

    test('a numeric id is not verifiable', () {
      expect(isVerifiableMd5('5240644'), isFalse);
    });

    test('empty and null are not verifiable', () {
      expect(isVerifiableMd5(''), isFalse);
      expect(isVerifiableMd5(null), isFalse);
    });

    test('wrong-length hex is not verifiable', () {
      expect(isVerifiableMd5('d41d8cd98f00b204e9800998ecf8427'), isFalse);
      expect(isVerifiableMd5('d41d8cd98f00b204e9800998ecf8427e0'), isFalse);
    });

    test('non-hex 32-char string is not verifiable', () {
      expect(isVerifiableMd5('zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'), isFalse);
    });
  });
}
