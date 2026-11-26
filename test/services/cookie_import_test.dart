import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/cookie_import.dart';

void main() {
  group('parseImportedCookie', () {
    test('JSON object', () {
      final parsed = parseImportedCookie(
        '{"remix_userid": "35899435", "remix_userkey": "abc123"}',
      );
      expect(parsed.userId, '35899435');
      expect(parsed.userKey, 'abc123');
    });

    test('JSON object ignores other keys and takes numeric ids', () {
      final parsed = parseImportedCookie(
        '{"remix_userid": 35899435, "remix_userkey": "abc123", '
        '"other": "x"}',
      );
      expect(parsed.userId, '35899435');
      expect(parsed.userKey, 'abc123');
    });

    test('JSON array of name/value objects (extension export)', () {
      final parsed = parseImportedCookie(
        '[{"name": "remix_userid", "value": "111"}, '
        '{"name": "remix_userkey", "value": "key111"}, '
        '{"name": "other", "value": "x"}]',
      );
      expect(parsed.userId, '111');
      expect(parsed.userKey, 'key111');
    });

    test('Netscape cookies.txt with tabs', () {
      const text = '# Netscape HTTP Cookie File\n'
          '.z-library.sk\tTRUE\t/\tTRUE\t1893456000\tremix_userid\t222\n'
          '.z-library.sk\tTRUE\t/\tTRUE\t1893456000\tremix_userkey\tkey222\n'
          '.z-library.sk\tTRUE\t/\tTRUE\t1893456000\tother\tzzz\n';
      final parsed = parseImportedCookie(text);
      expect(parsed.userId, '222');
      expect(parsed.userKey, 'key222');
    });

    test('Netscape cookies.txt with spaces instead of tabs', () {
      const text =
          '.z-library.sk TRUE / TRUE 1893456000 remix_userid 333\n'
          '.z-library.sk TRUE / TRUE 1893456000 remix_userkey key333\n';
      final parsed = parseImportedCookie(text);
      expect(parsed.userId, '333');
      expect(parsed.userKey, 'key333');
    });

    test('raw Cookie header', () {
      final parsed = parseImportedCookie(
        'other=x; remix_userid=444; remix_userkey=key444; foo=bar',
      );
      expect(parsed.userId, '444');
      expect(parsed.userKey, 'key444');
    });

    test('raw header tolerates quotes and case', () {
      final parsed = parseImportedCookie(
        'REMIX_USERID="555"; Remix_Userkey="key555"',
      );
      expect(parsed.userId, '555');
      expect(parsed.userKey, 'key555');
    });

    test('missing userid', () {
      expect(
        () => parseImportedCookie('remix_userkey=key1'),
        throwsA(
          isA<CookieImportException>().having(
            (e) => e.kind,
            'kind',
            CookieImportError.missingUserId,
          ),
        ),
      );
    });

    test('missing userkey', () {
      expect(
        () => parseImportedCookie('{"remix_userid": "1"}'),
        throwsA(
          isA<CookieImportException>().having(
            (e) => e.kind,
            'kind',
            CookieImportError.missingUserKey,
          ),
        ),
      );
    });

    test('empty text is unrecognized', () {
      expect(
        () => parseImportedCookie('   '),
        throwsA(
          isA<CookieImportException>().having(
            (e) => e.kind,
            'kind',
            CookieImportError.unrecognized,
          ),
        ),
      );
    });

    test('garbage without an equals sign is unrecognized', () {
      expect(
        () => parseImportedCookie('hello world'),
        throwsA(
          isA<CookieImportException>().having(
            (e) => e.kind,
            'kind',
            CookieImportError.unrecognized,
          ),
        ),
      );
    });

    test('broken JSON is unrecognized', () {
      expect(
        () => parseImportedCookie('{"remix_userid": '),
        throwsA(
          isA<CookieImportException>().having(
            (e) => e.kind,
            'kind',
            CookieImportError.unrecognized,
          ),
        ),
      );
    });
  });
}
