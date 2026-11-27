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

  group('pickApkAsset', () {
    test('取第一个 .apk 附件（大小写不敏感），跳过非 APK', () {
      final assets = [
        {'name': 'zlibx-v1.8.0.symbols.zip', 'size': 100},
        {'name': 'zlibx-v1.8.0.APK', 'size': 36000000},
        {'name': 'zlibx-v1.8.0.apk', 'size': 35000000},
      ];
      final picked = UpdateNotifier.pickApkAsset(assets);
      expect(picked?['name'], 'zlibx-v1.8.0.APK');
      expect(picked?['size'], 36000000);
    });

    test('没有 APK / 空 / 非列表：返 null', () {
      expect(
        UpdateNotifier.pickApkAsset([
          {'name': 'sha256sums.txt'},
        ]),
        isNull,
      );
      expect(UpdateNotifier.pickApkAsset([]), isNull);
      expect(UpdateNotifier.pickApkAsset(null), isNull);
      expect(UpdateNotifier.pickApkAsset('not a list'), isNull);
    });
  });

  group('parseSha256SumsFor', () {
    test('按文件名取行，* 标记照认，hash 小写归一', () {
      const sums =
          '$_hashLower  zlibx-v1.7.3.apk\n'
          '$_hash  *zlibx-v1.8.0.apk\n'
          '$_hashLower  other.apk\n';
      expect(
        UpdateNotifier.parseSha256SumsFor(sums, 'zlibx-v1.8.0.apk'),
        _hashLower,
      );
      expect(
        UpdateNotifier.parseSha256SumsFor(sums, 'zlibx-v1.7.3.apk'),
        _hashLower,
      );
    });

    test('找不到 / null：返 null', () {
      expect(
        UpdateNotifier.parseSha256SumsFor('$_hash  a.apk\n', 'b.apk'),
        isNull,
      );
      expect(UpdateNotifier.parseSha256SumsFor(null, 'a.apk'), isNull);
    });
  });
}
