import 'dart:io';

import 'package:flutter/services.dart';

import '../services/hive_service.dart';

/// 下载的更新 APK 的校验结果（计划一第 12–16 项）。
///
/// 两条防线缺一不可：
/// - SHA-256 对 Release 的 sha256sums.txt：防传输出错 / 文件被换；
/// - 签名证书与当前应用一致：防仓库被攻破后有人换一个同名 APK
///   （同一 Release 里的 sha256sums 防不住这种攻击，签名才是真防线）。
class ApkVerification {
  /// 文件本身的 SHA-256（小写 hex；文件读不到时为 null）。
  final String? sha256;

  /// 是否拿到了期望的 SHA-256 做比对（Release 没带 sha256sums.txt
  /// 时为 false，此时 [sha256Matches] 无意义）。
  final bool sha256Checked;

  /// 文件 SHA-256 与期望值一致（未比对时为 false）。
  final bool sha256Matches;

  /// APK 的签名证书 SHA-256 与当前应用一致。
  final bool signatureMatches;

  /// APK 的签名证书 SHA-256（读不到签名时为 null）。
  final String? apkFingerprint;

  /// 当前应用的签名证书 SHA-256。
  final String? currentFingerprint;

  /// 平台侧错误（如文件不存在、签名读不到）。非 null 时校验不通过。
  final String? error;

  const ApkVerification({
    this.sha256,
    this.sha256Checked = false,
    this.sha256Matches = false,
    this.signatureMatches = false,
    this.apkFingerprint,
    this.currentFingerprint,
    this.error,
  });

  /// 只有 SHA-256 无矛盾（或无需比对）且签名一致才算通过。
  bool get verified =>
      error == null &&
      (!sha256Checked || sha256Matches) &&
      signatureMatches;

  factory ApkVerification.fromMap(Map<Object?, Object?> map) {
    return ApkVerification(
      sha256: map['sha256'] as String?,
      sha256Checked: map['sha256Checked'] as bool? ?? false,
      sha256Matches: map['sha256Matches'] as bool? ?? false,
      signatureMatches: map['signatureMatches'] as bool? ?? false,
      apkFingerprint: map['apkFingerprint'] as String?,
      currentFingerprint: map['currentFingerprint'] as String?,
      error: map['error'] as String?,
    );
  }
}

/// 应用内更新的安装端（计划一第 13、15 项）：原生安装 intent +
/// 签名校验走 `zlibx/app_install` 通道；已下载安装包的持久化走
/// 设置 Hive 盒。
class AppInstaller {
  static const MethodChannel _channel =
      MethodChannel('zlibx/app_install');

  static const String downloadedApkPathKey = 'downloadedApkPath';
  static const String downloadedApkVersionKey = 'downloadedApkVersion';

  /// 校验 [path] 处的 APK：文件 SHA-256（与 [expectedSha256] 比对，
  /// 为 null 时只算、不比对）+ 签名证书与当前应用是否一致。
  /// 平台异常一律折成带 error 的结果，不抛。
  static Future<ApkVerification> verifyApk({
    required String path,
    String? expectedSha256,
  }) async {
    try {
      final result = await _channel
          .invokeMethod<Map<Object?, Object?>>('verifyApk', {
            'path': path,
            'expectedSha256': expectedSha256,
          });
      return ApkVerification.fromMap(result ?? const {});
    } on PlatformException catch (e) {
      return ApkVerification(error: e.message ?? e.code);
    } on MissingPluginException {
      return const ApkVerification(error: 'missing plugin');
    }
  }

  /// 打开系统安装界面安装 [path] 处的 APK。返回 false 表示
  /// intent 没发出去（无可用安装器等），不抛。
  static Future<bool> installApk(String path) async {
    try {
      return await _channel.invokeMethod<bool>('installApk', {
            'path': path,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 系统是否允许本应用安装未知来源应用
  /// （`canRequestPackageInstalls`）。
  static Future<bool> canInstallPackages() async {
    try {
      return await _channel.invokeMethod<bool>('canInstallPackages') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 打开系统“允许安装未知应用”设置页（带本应用包名）。
  static Future<bool> openUnknownSourcesSettings() async {
    try {
      return await _channel
              .invokeMethod<bool>('openUnknownSourcesSettings') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 记下已下载的安装包（路径 + 版本），供下次直接安装、免重复下载。
  static Future<void> saveDownloadedApk(
    String path,
    String version,
  ) async {
    final box = HiveService.settingsBox;
    await box.put(downloadedApkPathKey, path);
    await box.put(downloadedApkVersionKey, version);
  }

  /// 清掉已下载安装包的记录（文件本身由调用方处理）。
  static Future<void> clearDownloadedApk() async {
    final box = HiveService.settingsBox;
    await box.delete(downloadedApkPathKey);
    await box.delete(downloadedApkVersionKey);
  }

  /// 之前下载的安装包还能不能直接装：记录的版本是 [version]，
  /// 且文件还在盘上。返回可用路径，否则 null。
  static Future<String?> usablePersistedApkFor(String version) async {
    final box = HiveService.settingsBox;
    final path = box.get(downloadedApkPathKey) as String?;
    final savedVersion = box.get(downloadedApkVersionKey) as String?;
    if (path == null || path.isEmpty || savedVersion != version) {
      return null;
    }
    if (!await File(path).exists()) return null;
    return path;
  }
}
