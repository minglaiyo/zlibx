import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zlibx/services/app_install.dart';
import 'package:zlibx/services/hive_service.dart';

/// 安装包校验结果 + 持久化（计划一第 13 项、第 15 项安全要求）：
/// `ApkVerification.fromMap` 解析原生 `verifyApk` 的返回；
/// `AppInstaller` 把下好的包路径 + 版本存进设置盒子，文件还在且
/// 版本一致才算可用。
void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('app_install_hive');
    Hive.init(hiveDir.path);
    await Hive.openBox(HiveService.settingsBoxName);
    addTearDown(() async {
      await Hive.close();
      await hiveDir.delete(recursive: true);
    });
  });

  setUp(() async {
    final box = HiveService.settingsBox;
    await box.delete('downloadedApkPath');
    await box.delete('downloadedApkVersion');
  });

  group('ApkVerification.fromMap', () {
    Map<String, dynamic> goodMap() => <String, dynamic>{
      'sha256': 'a' * 64,
      'sha256Checked': true,
      'sha256Matches': true,
      'signatureMatches': true,
      'apkFingerprint': 'aa',
      'currentFingerprint': 'aa',
      'error': null,
    };

    test('全绿：verified', () {
      final v = ApkVerification.fromMap(goodMap());
      expect(v.verified, isTrue);
      expect(v.sha256, 'a' * 64);
      expect(v.apkFingerprint, 'aa');
      expect(v.error, isNull);
    });

    test('sha256 不匹配：verified false，error 为 verify', () {
      final v = ApkVerification.fromMap(
        goodMap()..['sha256Matches'] = false,
      );
      expect(v.verified, isFalse);
      expect(v.error, 'verify');
    });

    test('签名不一致：verified false，error 为 signature', () {
      final v = ApkVerification.fromMap(
        goodMap()..['signatureMatches'] = false,
      );
      expect(v.verified, isFalse);
      expect(v.error, 'signature');
    });

    test('原生报 error：verified false，error 原样透传', () {
      final v = ApkVerification.fromMap(
        goodMap()..['error'] = 'file not found',
      );
      expect(v.verified, isFalse);
      expect(v.error, 'file not found');
    });

    test('空 map：verified false，不抛', () {
      final v = ApkVerification.fromMap(<String, dynamic>{});
      expect(v.verified, isFalse);
      expect(v.error, isNull);
    });
  });

  group('AppInstaller persistence', () {
    test('保存后版本一致 + 文件在：可用；版本不符 / 文件没了：不可用', () async {
      final dir = await Directory.systemTemp.createTemp('app_install_apk');
      addTearDown(() => dir.delete(recursive: true));
      final apk = File('${dir.path}/zlibx-v1.8.0.apk');
      await apk.writeAsBytes([0x50, 0x4B]);

      await AppInstaller.saveDownloadedApk(apk.path, '1.8.0');
      expect(
        await AppInstaller.usablePersistedApkFor('1.8.0'),
        apk.path,
      );
      // 版本不符：不复用。
      expect(await AppInstaller.usablePersistedApkFor('1.7.3'), isNull);
      // 文件删了：不复用。
      await apk.delete();
      expect(await AppInstaller.usablePersistedApkFor('1.8.0'), isNull);
    });

    test('clearDownloadedApk 清掉记录', () async {
      await AppInstaller.saveDownloadedApk('/tmp/x.apk', '1.8.0');
      await AppInstaller.clearDownloadedApk();
      expect(await AppInstaller.usablePersistedApkFor('1.8.0'), isNull);
    });
  });
}
