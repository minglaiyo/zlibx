import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/providers/update_provider.dart';

/// 更新校验信息解析(审查 B4,2026-11-20):sha256sums.txt 与
/// apksigner --print-certs 输出的两种格式,小写归一,脏输入返 null。
const _hash = '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF';
const _hashLower =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  group('parseSha256Sums', () {
    test('sha256sums 行取首个 64-hex token 并小写归一', () {
      expect(UpdateNotifier.parseSha256Sums('$_hash  zlibx-v1.6.2.apk\n'),
          _hashLower);
    });

    test('空行/脏行跳过,取第一个合法行', () {
      expect(
        UpdateNotifier.parseSha256Sums(
          '\n   \ngarbage line\n$_hash  a.apk\n',
        ),
        _hashLower,
      );
    });

    test('无合法 hash / null:返 null', () {
      expect(UpdateNotifier.parseSha256Sums('nope\n'), isNull);
      expect(UpdateNotifier.parseSha256Sums(null), isNull);
      expect(UpdateNotifier.parseSha256Sums(''), isNull);
    });
  });

  group('parseSignerFingerprint', () {
    test('apksigner 证书行提取 digest 并小写归一', () {
      expect(
        UpdateNotifier.parseSignerFingerprint(
          'Signer #1 certificate SHA-256 digest: $_hash\n'
          'Signer #1 certificate SHA-1 digest: deadbeef\n',
        ),
        _hashLower,
      );
    });

    test('无匹配 / null:返 null', () {
      expect(UpdateNotifier.parseSignerFingerprint('nothing here\n'), isNull);
      expect(UpdateNotifier.parseSignerFingerprint(null), isNull);
    });
  });
}
