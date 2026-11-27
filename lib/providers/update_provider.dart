import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/hive_service.dart';
import '../utils/diagnostics.dart';
import '../services/http_client.dart';
import '../services/update/update_manifest.dart';
import '../utils/app_log.dart';


export '../services/update/update_manifest.dart' show UpdateLink;

/// Update checker state.
///
/// Formerly process-global statics on a now-removed `UpdateService`;
/// the same values, timing and dismiss semantics now live on this
/// Notifier's state. The update link host whitelist is in
/// `lib/services/update/update_manifest.dart` (S7).
class UpdateState {
  /// GitHub Releases 数据源
  static const String releaseApiUrl =
      'https://api.github.com/repos/minglaiyo/zlibx/releases/latest';

  /// 项目 Releases 页（minglaiyo/zlibx），PanSync 发版时同步网盘链接到这里
  static const String downloadUrlDefault =
      'https://github.com/minglaiyo/zlibx/releases';

  /// Remote version info
  final String? latestVersion;
  final String? currentVersion;
  final String? downloadUrl;
  final String? releaseUrl;
  final Map<String, String>? changelog;
  final List<UpdateLink> links;

  /// Release 资产里的校验信息（审查 B4，2026-11-20）：APK 的 SHA-256 与
  /// 签名证书 SHA-256 指纹，best-effort 从 Release 资产
  /// （sha256sums.txt / signing-fingerprint.txt）拉取。缺失或拉取失败
  /// 为 null——对话框随之隐藏校验块。纵深防御：签名不一致时 Android
  /// 本就拒绝覆盖安装，这里给用户一个可核对的凭据。
  final String? sha256;
  final String? signerFingerprint;

  /// 应用内下载用的 APK 附件（计划一第 12 项）：Release 资产里
  /// 第一个 `.apk` 文件的下载地址、文件名与大小。没有 APK 附件
  /// 时全为 null，对话框退回原来的渠道按钮。
  final String? apkUrl;
  final String? apkName;
  final int? apkSize;

  /// How many manifest link lines were dropped (host off the allow-list,
  /// non-https, …). The update dialog warns about the count.
  final int droppedLinkCount;

  final bool forceUpdate;
  final bool hasUpdate;

  /// Flag to indicate app is blocked due to force update
  /// When true, search and download features should be disabled
  final bool isBlocked;

  const UpdateState({
    this.latestVersion,
    this.currentVersion,
    this.downloadUrl = downloadUrlDefault,
    this.releaseUrl,
    this.changelog,
    this.links = const [],
    this.sha256,
    this.signerFingerprint,
    this.apkUrl,
    this.apkName,
    this.apkSize,
    this.droppedLinkCount = 0,
    this.forceUpdate = false,
    this.hasUpdate = false,
    this.isBlocked = false,
  });

  UpdateState copyWith({
    String? latestVersion,
    String? currentVersion,
    String? downloadUrl,
    String? releaseUrl,
    Map<String, String>? changelog,
    List<UpdateLink>? links,
    String? sha256,
    String? signerFingerprint,
    String? apkUrl,
    String? apkName,
    int? apkSize,
    int? droppedLinkCount,
    bool? forceUpdate,
    bool? hasUpdate,
    bool? isBlocked,
  }) {
    return UpdateState(
      latestVersion: latestVersion ?? this.latestVersion,
      currentVersion: currentVersion ?? this.currentVersion,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      releaseUrl: releaseUrl ?? this.releaseUrl,
      changelog: changelog ?? this.changelog,
      links: links ?? this.links,
      sha256: sha256 ?? this.sha256,
      signerFingerprint: signerFingerprint ?? this.signerFingerprint,
      apkUrl: apkUrl ?? this.apkUrl,
      apkName: apkName ?? this.apkName,
      apkSize: apkSize ?? this.apkSize,
      droppedLinkCount: droppedLinkCount ?? this.droppedLinkCount,
      forceUpdate: forceUpdate ?? this.forceUpdate,
      hasUpdate: hasUpdate ?? this.hasUpdate,
      isBlocked: isBlocked ?? this.isBlocked,
    );
  }

  /// Get changelog text for current locale
  String getChangelog(String locale) {
    if (changelog == null) return '';
    return changelog![locale] ?? changelog!['en'] ?? '';
  }
}

/// Update checker notifier for checking new app versions.
///
/// 数据源：GitHub Releases API。tag push 后 CI workflow 自动建 Release，
/// 这里直接拉 `releases/latest`：
/// - tag_name (去掉 v 前缀) → 最新版本号
/// - body                   → changelog + 更新清单（强制更新 / 网盘渠道，
///   见 [UpdateManifest]）
///
/// 网络请求 24h 一次，但每次拿到的 Release 会缓存进 Hive：跳过请求时用缓存
/// 重新计算状态，保证强制更新在 App 重启后依然生效。
class UpdateNotifier extends Notifier<UpdateState> {
  static const String _lastCheckKey = 'last_update_check';
  static const String _dismissedVersionKey = 'dismissed_version';
  static const String _cachedTagKey = 'update_cached_tag';
  static const String _cachedBodyKey = 'update_cached_body';
  static const String _cachedReleaseUrlKey = 'update_cached_release_url';
  static const String _cachedShaKey = 'update_cached_sha256';
  static const String _cachedFingerprintKey = 'update_cached_fingerprint';
  static const String _cachedApkUrlKey = 'update_cached_apk_url';
  static const String _cachedApkNameKey = 'update_cached_apk_name';
  static const String _cachedApkSizeKey = 'update_cached_apk_size';

  /// Check interval: once per day
  static const Duration _checkInterval = Duration(hours: 24);

  @override
  UpdateState build() => const UpdateState();

  /// Check for updates (non-blocking, silent on errors)
  ///
  /// 未到检查间隔时不发请求，直接用上次缓存的 Release 计算结果。
  Future<bool> checkForUpdate({bool force = false}) async {
    try {
      if (state.currentVersion == null) {
        final version = (await PackageInfo.fromPlatform()).version;
        state = state.copyWith(currentVersion: version);
      }

      if (!force && !_shouldCheck()) {
        AppLog.report(
          'UpdateService: Skipping request (checked recently), using cache',
          tag: 'update_provider',
        );
        return _applyCached();
      }

      // Cancel the underlying request on timeout: otherwise the
      // releases fetch keeps running in the background after the
      // check has already fallen back to the cache. The Dio is a
      // single-use instance: close it in a finally so a failed or
      // timed-out request does not leak its HttpClient (O13).
      final cancelToken = CancelToken();
      final dio = createDio();
      final Response<dynamic> response;
      try {
        response = await dio
            .getUri(
              Uri.parse(UpdateState.releaseApiUrl),
              options: Options(
                headers: {
                  // 不带 token 走匿名 60 次/小时/IP — 对 24h 检查间隔够用
                  'Accept': 'application/vnd.github+json',
                  'X-GitHub-Api-Version': '2022-11-28',
                },
              ),
              cancelToken: cancelToken,
            )
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                cancelToken.cancel();
                throw TimeoutException('Update check timed out after 10s');
              },
            );
      } finally {
        dio.close();
      }

      if (response.statusCode != 200) {
        final body = response.data?.toString() ?? '';
        AppLog.report(
          'UpdateService: GitHub releases API ${response.statusCode}: '
          '${body.length > 200 ? body.substring(0, 200) : body}',
          tag: 'update_provider',
        );
        return _applyCached();
      }

      final data = response.data as Map<String, dynamic>;
      final tagName = data['tag_name'] as String?;
      if (tagName == null || tagName.isEmpty) {
        AppLog.report(
          'UpdateService: release missing tag_name',
          tag: 'update_provider',
        );
        return _applyCached();
      }
      final body = (data['body'] as String? ?? '').trim();
      final htmlUrl = data['html_url'] as String?;

      // 草稿 / 预发布不走应用内更新：releases/latest 本来就不返回
      // 它们，这里是防御——万一哪天接口变了，也不要把半成品推给
      // 用户下载；沿用上次缓存的 Release 判定。
      if (data['draft'] == true || data['prerelease'] == true) {
        AppLog.report(
          'UpdateService: latest release is draft/prerelease, skipping',
          tag: 'update_provider',
        );
        return _applyCached();
      }

      // 应用内下载的目标（计划一第 12 项）：Release 资产里第一个
      // `.apk` 文件。
      final apkAsset = pickApkAsset(data['assets']);
      final apkName = apkAsset == null
          ? null
          : apkAsset['name'] as String?;
      final apkUrl = apkAsset == null
          ? null
          : apkAsset['browser_download_url'] as String?;
      final apkSize = apkAsset == null
          ? null
          : apkAsset['size'] as int?;

      // 校验信息（审查 B4）：best-effort，任何失败都留 null，绝不影响
      // 更新判定本身。
      final assetDio = createDio();
      String? sha256;
      String? signerFingerprint;
      try {
        // SHA-256 按 APK 文件名取（sums 文件里可能有多行）；取不到
        // 时退回首个合法 hash，保持旧的对话框校验块行为。
        final sumsText = await _fetchAssetText(
          assetDio,
          data,
          'sha256sums.txt',
        );
        sha256 = apkName == null
            ? parseSha256Sums(sumsText)
            : parseSha256SumsFor(sumsText, apkName) ??
                parseSha256Sums(sumsText);
        signerFingerprint = parseSignerFingerprint(
          await _fetchAssetText(assetDio, data, 'signing-fingerprint.txt'),
        );
      } on Object catch (error) {
        // 校验信息是可选装饰——但不无声（审查 v2 P2-2）。
        logIgnored('update_verify_assets', error);
      } finally {
        assetDio.close();
      }

      final box = HiveService.settingsBox;
      await box.put(_cachedTagKey, tagName);
      await box.put(_cachedBodyKey, body);
      await box.put(_cachedReleaseUrlKey, htmlUrl);
      await box.put(_cachedShaKey, sha256);
      await box.put(_cachedFingerprintKey, signerFingerprint);
      await _putOrDelete(box, _cachedApkUrlKey, apkUrl);
      await _putOrDelete(box, _cachedApkNameKey, apkName);
      await _putOrDelete(box, _cachedApkSizeKey, apkSize);
      await box.put(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);

      return _apply(
        tagName,
        body,
        htmlUrl,
        sha256: sha256,
        signerFingerprint: signerFingerprint,
        apkUrl: apkUrl,
        apkName: apkName,
        apkSize: apkSize,
      );
    } catch (e) {
      // Network-layer exception text can carry URLs or response
      // fragments: log the type only.
      AppLog.report(
        'UpdateService: Error checking for update: ${e.runtimeType}',
        tag: 'update_provider',
      );
      return _applyCached();
    }
  }

  bool _applyCached() {
    final box = HiveService.settingsBox;
    final tag = box.get(_cachedTagKey) as String?;
    if (tag == null || state.currentVersion == null) return false;
    return _apply(
      tag,
      box.get(_cachedBodyKey) as String? ?? '',
      box.get(_cachedReleaseUrlKey) as String?,
      sha256: box.get(_cachedShaKey) as String?,
      signerFingerprint: box.get(_cachedFingerprintKey) as String?,
      apkUrl: box.get(_cachedApkUrlKey) as String?,
      apkName: box.get(_cachedApkNameKey) as String?,
      apkSize: box.get(_cachedApkSizeKey) as int?,
    );
  }

  /// 存值或清键：Hive 对 null 值的处理因版本而异，显式删键最稳妥。
  static Future<void> _putOrDelete(
    Box<dynamic> box,
    String key,
    Object? value,
  ) async {
    if (value == null) {
      await box.delete(key);
    } else {
      await box.put(key, value);
    }
  }

  bool _apply(
    String tagName,
    String body,
    String? htmlUrl, {
    String? sha256,
    String? signerFingerprint,
    String? apkUrl,
    String? apkName,
    int? apkSize,
  }) {
    final current = state.currentVersion!;
    final latest = tagName.startsWith('v') ? tagName.substring(1) : tagName;
    final manifest = UpdateManifest.parse(body);

    // 双语都用同一份（后续如果想分语言可以解析 ## zh / ## en 段）
    final changelog = {'zh': manifest.notes, 'en': manifest.notes};
    final hasUpdate = isNewerVersion(latest, current);

    final belowMin =
        manifest.minVersion != null &&
        isNewerVersion(manifest.minVersion!, current);
    final forceUpdate = hasUpdate && (manifest.forceAll || belowMin);

    // NOTE: releaseUrl is built directly (not via copyWith) because
    // htmlUrl may legitimately be null and copyWith cannot express
    // "set this field to null". The API-returned html_url feeds the
    // dialog's "GitHub" button, so it goes through the same allow-list
    // as the manifest links (S7: github.com only under this repo's
    // path): a compromised Release body cannot point the dialog at
    // another repo. An invalid URL falls back to null and the button
    // is hidden; the releases-page downloadUrl default still applies.
    state = UpdateState(
      latestVersion: latest,
      currentVersion: current,
      releaseUrl: htmlUrl != null && UpdateManifest.isAllowedLink(htmlUrl)
          ? htmlUrl
          : null,
      changelog: changelog,
      links: manifest.links,
      sha256: sha256,
      signerFingerprint: signerFingerprint,
      apkUrl: apkUrl,
      apkName: apkName,
      apkSize: apkSize,
      droppedLinkCount: manifest.droppedLinkCount,
      hasUpdate: hasUpdate,
      forceUpdate: forceUpdate,
      isBlocked: forceUpdate,
    );

    AppLog.report(
      'UpdateService: Current=$current, Latest=$latest, '
      'HasUpdate=$hasUpdate, Force=$forceUpdate, Links=${manifest.links.length}, '
      'DroppedLinks=${manifest.droppedLinkNames}',
      tag: 'update_provider',
    );
    return hasUpdate;
  }

  /// Check if we should perform update check
  bool _shouldCheck() {
    final lastCheck = HiveService.settingsBox.get(_lastCheckKey);
    if (lastCheck == null) return true;

    final lastCheckTime = DateTime.fromMillisecondsSinceEpoch(lastCheck as int);
    return DateTime.now().difference(lastCheckTime) > _checkInterval;
  }

  /// Check if user has dismissed this version
  bool isVersionDismissed() {
    final dismissed = HiveService.settingsBox.get(_dismissedVersionKey);
    return dismissed == state.latestVersion;
  }

  /// 拉一个 Release 资产的文本内容（校验文件都很小）。资产缺失 /
  /// 非 200 / 任何异常都返回 null。
  Future<String?> _fetchAssetText(
    Dio dio,
    Map<String, dynamic> release,
    String name,
  ) async {
    final assets = release['assets'];
    if (assets is! List) return null;
    String? url;
    for (final asset in assets) {
      if (asset is Map && asset['name'] == name) {
        url = asset['browser_download_url'] as String?;
        break;
      }
    }
    if (url == null || url.isEmpty) return null;
    final response = await dio
        .get(
          url,
          options: Options(
            responseType: ResponseType.plain,
            headers: const {'Accept': 'application/octet-stream'},
          ),
        )
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) return null;
    return response.data?.toString();
  }

  /// Release 资产里找 APK：第一个 `.apk` 文件。找不到返回 null——
  /// 对话框退回原来的渠道按钮。
  @visibleForTesting
  static Map<String, dynamic>? pickApkAsset(Object? assets) {
    if (assets is! List) return null;
    for (final asset in assets) {
      if (asset is Map<String, dynamic>) {
        final name = asset['name'] as String?;
        if (name != null && name.toLowerCase().endsWith('.apk')) {
          return asset;
        }
      }
    }
    return null;
  }

  /// `<hash>  <filename>`（sha256sums 格式）：第一个非空行的首个
  /// 64-hex token，小写归一。
  @visibleForTesting
  static String? parseSha256Sums(String? content) {
    if (content == null) return null;
    for (final line in content.split('\n')) {
      final token = line.trim().split(RegExp(r'\s+')).first;
      if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(token)) {
        return token.toLowerCase();
      }
    }
    return null;
  }

  /// sha256sums.txt 里找 [fileName] 那一行的 hash。文件名按
  /// basename 比对（sums 文件里只有文件名，没有路径）；` *name`
  ///（二进制模式标记）同样认。找不到返回 null。
  @visibleForTesting
  static String? parseSha256SumsFor(String? content, String fileName) {
    if (content == null) return null;
    final wanted = fileName.split('/').last.toLowerCase();
    for (final line in content.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final token = parts.first;
      final name = parts
          .sublist(1)
          .join(' ')
          .replaceFirst(RegExp(r'^\*'), '')
          .toLowerCase();
      if (name == wanted &&
          RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(token)) {
        return token.toLowerCase();
      }
    }
    return null;
  }

  /// `Signer #1 certificate SHA-256 digest: <hex>`（apksigner
  /// --print-certs 格式），小写归一。
  @visibleForTesting
  static String? parseSignerFingerprint(String? content) {
    if (content == null) return null;
    for (final line in content.split('\n')) {
      final match = RegExp(
        r'SHA-256 digest:\s*([0-9a-fA-F]{64})',
      ).firstMatch(line);
      if (match != null) return match.group(1)!.toLowerCase();
    }
    return null;
  }

  /// Dismiss the current update notification
  Future<void> dismissUpdate() async {
    if (state.latestVersion != null) {
      await HiveService.settingsBox.put(
        _dismissedVersionKey,
        state.latestVersion,
      );
    }
  }
}

/// Global update state — cached across the app lifecycle.
final updateProvider = NotifierProvider<UpdateNotifier, UpdateState>(
  UpdateNotifier.new,
);
