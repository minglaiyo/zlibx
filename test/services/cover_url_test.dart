import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/utils/cover_cache.dart';

void main() {
  group('coverUrlAtWidth', () {
    const covers100 =
        'https://s3proxy-alp2-covers.cdn-zlib.sk/covers100/collections/userbooks/a2a6c4c26ea0ffbea8e239e3dee21483a3f904a82dd2f943b3022154e60ad379.jpg';

    test('rewrites covers100 to the requested width', () {
      expect(
        coverUrlAtWidth(covers100, 300),
        'https://s3proxy-alp2-covers.cdn-zlib.sk/covers300/collections/userbooks/a2a6c4c26ea0ffbea8e239e3dee21483a3f904a82dd2f943b3022154e60ad379.jpg',
      );
      expect(
        coverUrlAtWidth(covers100, 800),
        'https://s3proxy-alp2-covers.cdn-zlib.sk/covers800/collections/userbooks/a2a6c4c26ea0ffbea8e239e3dee21483a3f904a82dd2f943b3022154e60ad379.jpg',
      );
    });

    test('rewrites any coversN segment, not just covers100', () {
      const covers200 =
          'https://s3proxy-alp2-covers.cdn-zlib.sk/covers200/collections/userbooks/abc.jpg';
      expect(
        coverUrlAtWidth(covers200, 300),
        'https://s3proxy-alp2-covers.cdn-zlib.sk/covers300/collections/userbooks/abc.jpg',
      );
    });

    test('leaves non-covers URLs untouched', () {
      const anna = 'https://annas-archive.org/covers/abc.jpg';
      expect(coverUrlAtWidth(anna, 300), anna);
      const local = '/img/cover-not-exists.png';
      expect(coverUrlAtWidth(local, 300), local);
      expect(coverUrlAtWidth('', 300), '');
    });

    test('clamps the width to the verified 100..800 range', () {
      expect(coverUrlAtWidth(covers100, 50),
          contains('/covers100/collections/'));
      expect(coverUrlAtWidth(covers100, 2000),
          contains('/covers800/collections/'));
    });
  });
}
