import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/utils/host_utils.dart';

void main() {
  group('isZlibFamilyHost', () {
    test('accepts the Z-Library family, including subdomains', () {
      for (final host in [
        'z-library.sk',
        'reader.z-library.sk',
        'z-lib.fm',
        'Z-LIB.GD',
        'z-library.mn',
        'bookroom.lifestyle',
        'reader.bookroom.lifestyle',
        'z-library.im',
      ]) {
        expect(isZlibFamilyHost(host), isTrue, reason: host);
      }
    });

    test('rejects look-alike and unrelated hosts', () {
      for (final host in [
        'z-library.evil.com',
        'z-library.sk.evil.com',
        'notbookroom.xyz',
        'evilz-library.sk',
        'bookroom',
        'z-lib',
        'localhost',
        '1.2.3.4',
        'z-library.sk:443',
        'z-library..sk',
        '',
        // Any TLD paired with a family label is not family.
        'z-lib.xyz',
        'z-library.top',
        'bookroom.xyz',
        'evil.z-lib.xyz',
        // singlelogin.* is dead: .se is parked for sale, .re and
        // 1lib.singlelogin.se do not resolve (checked 2026-11-11).
        'singlelogin.se',
        'singlelogin.re',
        '1lib.singlelogin.se',
      ]) {
        expect(isZlibFamilyHost(host), isFalse, reason: host);
      }
    });
  });

  group('isAnnasFamilyHost', () {
    test('accepts the Anna search hosts (exact match, case-insensitive)', () {
      for (final host in [
        'annas-archive.org',
        'annas-archive.gl',
        'annas-archive.pk',
        'annas-archive.gd',
        'ANNAS-ARCHIVE.ORG',
      ]) {
        expect(isAnnasFamilyHost(host), isTrue, reason: host);
      }
    });

    test('rejects non-search hosts, subdomains and look-alikes', () {
      for (final host in [
        // software.annas-archive.gl is a GitLab instance on the same
        // annas page, not a search host — it must never receive the key.
        'software.annas-archive.gl',
        // Download servers are not search hosts.
        'yqrii5.org',
        'wbsg8v.xyz',
        // No subdomain wildcard: only the bare search hosts count.
        'www.annas-archive.org',
        'foo.annas-archive.gl',
        // Any TLD not on the list is not family.
        'annas-archive.xyz',
        'annas-archive.top',
        'annas-archive.se',
        'annas-archive.li',
        // Look-alikes and malformed input.
        'annas-archive.gl.evil.com',
        'evilannas-archive.gl',
        'annas-archive',
        'localhost',
        'annas-archive.gl:443',
        'annas-archive..gl',
        '',
      ]) {
        expect(isAnnasFamilyHost(host), isFalse, reason: host);
      }
    });
  });

  group('readerDomainFor', () {
    test('maps a line to its reader host', () {
      expect(readerDomainFor('z-lib.fm'), 'reader.z-lib.fm');
      expect(readerDomainFor('zh.z-lib.fm'), 'reader.z-lib.fm');
      expect(readerDomainFor('bookroom.lifestyle'),
          'reader.bookroom.lifestyle');
    });
  });

  group('isTrustedReaderUrl', () {
    test('accepts the line\'s own reader and bare domain over https', () {
      for (final url in [
        'https://reader.z-lib.fm/read/1',
        'https://z-lib.fm/login',
        'https://reader.z-lib.fm:443/x',
      ]) {
        expect(isTrustedReaderUrl(url, 'z-lib.fm'), isTrue, reason: url);
      }
      expect(isTrustedReaderUrl('https://reader.z-lib.fm/r', 'zh.z-lib.fm'),
          isTrue);
      expect(isTrustedReaderUrl('https://reader.m.cc/r', 'm.cc:8443'), isTrue);
    });

    test('rejects foreign hosts, http and userinfo tricks', () {
      for (final url in [
        'https://evil.com/read/1',
        'https://reader.z-lib.fm.evil.com/x',
        'https://notz-lib.fm/x',
        'https://z-lib.fm@evil.com/x',
        'http://reader.z-lib.fm/x',
        'javascript:alert(1)',
        '',
      ]) {
        expect(isTrustedReaderUrl(url, 'z-lib.fm'), isFalse, reason: url);
      }
      expect(isTrustedReaderUrl('https://reader.z-lib.fm/x', ''), isFalse);
    });
  });
}
