import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/hive_service.dart';
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
      // check has already fallen back to the cache.
      final cancelToken = CancelToken();
      final response = await createDio()
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

      final box = HiveService.settingsBox;
      await box.put(_cachedTagKey, tagName);
      await box.put(_cachedBodyKey, body);
      await box.put(_cachedReleaseUrlKey, htmlUrl);
      await box.put(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);

      return _apply(tagName, body, htmlUrl);
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
    );
  }

  bool _apply(String tagName, String body, String? htmlUrl) {
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
    // "set this field to null".
    state = UpdateState(
      latestVersion: latest,
      currentVersion: current,
      releaseUrl: htmlUrl,
      changelog: changelog,
      links: manifest.links,
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
final updateProvider =
    NotifierProvider<UpdateNotifier, UpdateState>(UpdateNotifier.new);
