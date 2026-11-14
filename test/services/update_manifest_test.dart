import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/update/update_manifest.dart';

void main() {
  group('update link allow-list', () {
    test('keeps documented netdisks and GitHub, drops everything else', () {
      final m = UpdateManifest.parse('''
notes
<!-- olib-update
min_version: 1.4.0
百度网盘: https://pan.baidu.com/s/abc?pwd=1234
夸克网盘: https://pan.quark.cn/s/xyz
Evil: https://evil.example.com/zlibx.apk
Plain: http://pan.baidu.com/s/abc
Spoof: https://pan.baidu.com@evil.example.com/x
Suffix: https://pan.baidu.com.evil.example.com/x
-->''');
      expect(m.links.map((l) => l.name), ['百度网盘', '夸克网盘']);
      expect(m.minVersion, '1.4.0');
      // Dropped links are counted (names only) instead of silently
      // disappearing, so the update dialog can warn about them.
      expect(m.droppedLinkNames, ['Evil', 'Plain', 'Spoof', 'Suffix']);
      expect(m.droppedLinkCount, 4);
    });

    test('non-link lines are not counted as dropped', () {
      final m = UpdateManifest.parse('''
<!-- olib-update
min_version: 1.4.0
备注：请用官网下载
百度网盘: https://pan.baidu.com/s/abc
-->''');
      expect(m.links.map((l) => l.name), ['百度网盘']);
      expect(m.droppedLinkCount, 0);
    });

    test('subdomains of an allowed host pass, look-alikes do not', () {
      // github.com is narrowed to this repo's paths (S7): a gist or any
      // other repo is not a download channel for this app.
      expect(UpdateManifest.isAllowedLink('https://gist.github.com/x'),
          isFalse);
      expect(
        UpdateManifest.isAllowedLink(
          'https://github.com/minglaiyo/zlibx/releases',
        ),
        isTrue,
      );
      expect(
        UpdateManifest.isAllowedLink('https://github.com/minglaiyo/zlibx'),
        isTrue,
      );
      expect(
        UpdateManifest.isAllowedLink(
          'https://github.com/other/zlibx/releases',
        ),
        isFalse,
      );
      expect(
        UpdateManifest.isAllowedLink(
          'https://github.com/minglaiyo/other/releases',
        ),
        isFalse,
      );
      expect(UpdateManifest.isAllowedLink('https://notgithub.com/x'), isFalse);
      expect(UpdateManifest.isAllowedLink('ftp://github.com/x'), isFalse);
    });

    test('github release asset links under this repo pass', () {
      expect(
        UpdateManifest.isAllowedLink(
          'https://github.com/minglaiyo/zlibx/releases/download/v1.5.8/zlibx.apk',
        ),
        isTrue,
      );
    });
  });

  group('isNewerVersion', () {
    test('core comparison (unchanged behaviour)', () {
      expect(isNewerVersion('1.5.9', '1.5.8'), isTrue);
      expect(isNewerVersion('1.5.8', '1.5.8'), isFalse);
      expect(isNewerVersion('1.5.8', '1.5.9'), isFalse);
      expect(isNewerVersion('1.6', '1.5.8'), isTrue);
    });

    test('a higher build number counts as newer (S7)', () {
      expect(isNewerVersion('1.5.8+10509', '1.5.8+10508'), isTrue);
      expect(isNewerVersion('1.5.8+10508', '1.5.8+10508'), isFalse);
      expect(isNewerVersion('1.5.8+10508', '1.5.8'), isTrue);
    });

    test('a pre-release is older than the same release (S7)', () {
      expect(isNewerVersion('1.5.8', '1.5.8-beta'), isTrue);
      expect(isNewerVersion('1.5.8-beta', '1.5.8'), isFalse);
      expect(isNewerVersion('1.5.8-beta.2', '1.5.8-beta.1'), isTrue);
      expect(isNewerVersion('1.5.8-beta.1', '1.5.8-beta.2'), isFalse);
      expect(isNewerVersion('1.5.8-rc.1', '1.5.8-beta.9'), isTrue);
    });
  });

  group('[FORCE] must be on its own line (O4)', () {
    test('an inline mention does not force an update', () {
      final m = UpdateManifest.parse(
        '移除了 [FORCE] 标记\n<!-- olib-update\nmin_version: 1.4.0\n-->',
      );
      expect(m.forceAll, isFalse);
      // The inline mention is changelog text: it stays in the notes.
      expect(m.notes, contains('[FORCE]'));
    });

    test('a [FORCE] line of its own forces an update', () {
      final m = UpdateManifest.parse(
        '更新说明\n[FORCE]\n<!-- olib-update\nmin_version: 1.4.0\n-->',
      );
      expect(m.forceAll, isTrue);
      // The own-line marker is stripped from the notes.
      expect(m.notes, isNot(contains('[FORCE]')));
    });

    test('[FORCE_UPDATE] on its own line also forces an update', () {
      final m = UpdateManifest.parse('[FORCE_UPDATE]');
      expect(m.forceAll, isTrue);
    });

    test('a line with extra text around [FORCE] does not force', () {
      final m = UpdateManifest.parse('请注意 [FORCE] 本次更新');
      expect(m.forceAll, isFalse);
    });
  });
}
