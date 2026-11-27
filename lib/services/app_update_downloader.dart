import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../services/http_client.dart';
import '../services/resumable_downloader.dart';
import 'app_install.dart';

/// 应用内更新下载的状态机（计划一第 12–14 项）。
///
/// 暂停是真暂停：[pause] 只是取消本次请求，断点文件与 `.meta`
/// 校验 sidecar 都留在盘上，[resume] 重新调起下载时
/// [ResumableDownloader] 用 Range 从断点续传——不用参考实现
/// （Gjbone v0.2.1）那种只停读 socket 的 StreamSubscription
/// pause/resume，进程死了进度就丢。
enum AppUpdateDownloadStatus {
  idle,
  downloading,
  paused,
  completed,
  failed,
}

/// 下载失败的原因（UI 按它取本地化文案）。
enum AppUpdateDownloadError {
  /// 网络 / 内容异常（HTML 墙页、文件头不对、截断等）。
  download,

  /// SHA-256 与 Release 的 sha256sums.txt 对不上。
  verify,

  /// APK 签名证书与当前应用不一致。
  signature,
}

class AppUpdateDownloadState {
  final AppUpdateDownloadStatus status;
  final int received;
  final int total;

  /// 正在下载 / 已下载完的版本号。
  final String? version;

  /// Release 附件的下载地址。
  final String? apkUrl;

  /// 已下载完的 APK 路径（completed 时）。
  final String? apkPath;

  /// Release 的 sha256sums.txt 里该 APK 的期望 SHA-256。
  final String? expectedSha256;

  final AppUpdateDownloadError? error;

  /// 下载完了但系统不允许安装未知应用，等用户去设置里允许。
  final bool needsUnknownSources;

  const AppUpdateDownloadState({
    this.status = AppUpdateDownloadStatus.idle,
    this.received = 0,
    this.total = -1,
    this.version,
    this.apkUrl,
    this.apkPath,
    this.expectedSha256,
    this.error,
    this.needsUnknownSources = false,
  });

  /// 0..1；总大小未知时为 null。
  double? get progress => total > 0 ? received / total : null;

  AppUpdateDownloadState copyWith({
    AppUpdateDownloadStatus? status,
    int? received,
    int? total,
    String? version,
    String? apkUrl,
    String? apkPath,
    String? expectedSha256,
    AppUpdateDownloadError? error,
    bool? needsUnknownSources,
  }) {
    return AppUpdateDownloadState(
      status: status ?? this.status,
      received: received ?? this.received,
      total: total ?? this.total,
      version: version ?? this.version,
      apkUrl: apkUrl ?? this.apkUrl,
      apkPath: apkPath ?? this.apkPath,
      expectedSha256: expectedSha256 ?? this.expectedSha256,
      error: error ?? this.error,
      needsUnknownSources: needsUnknownSources ?? this.needsUnknownSources,
    );
  }
}

/// 应用内更新下载（计划一第 12 项）+ 安装（第 13、15 项）。
///
/// 目标目录优先用外部应用专属目录：安装前的签名预检
/// （`PackageManager.getPackageArchiveInfo`）跑在 system_server
/// 里，读不到应用私有目录（`getFilesDir`）下的文件；外部专属
/// 目录不需要额外权限，卸载时系统会一并清掉。
class AppUpdateDownloader extends Notifier<AppUpdateDownloadState> {
  CancelToken? _cancelToken;
  bool _pauseRequested = false;
  bool _cancelRequested = false;
  int _runId = 0;

  @override
  AppUpdateDownloadState build() => const AppUpdateDownloadState();

  /// 更新 APK 的保存路径：`<外部专属目录>/updates/zlibx-v<版本>.apk`，
  /// 外部存储不可用时回落到应用私有目录。
  @visibleForTesting
  static Future<String> apkSavePath(String version) async {
    final external = await getExternalStorageDirectory().catchError(
      (_) => null,
    );
    final base = external ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/updates');
    if (!await dir.exists()) await dir.create(recursive: true);
    return '${dir.path}/zlibx-v$version.apk';
  }

  /// 开始（或从断点继续）下载 [apkUrl] 的更新包。
  /// 已有完整且校验通过的文件时直接跳到完成态，不重复下载。
  Future<void> start({
    required String url,
    required String version,
    String? expectedSha256,
  }) async {
    if (state.status == AppUpdateDownloadStatus.downloading) return;
    final savePath = await apkSavePath(version);
    _pauseRequested = false;
    _cancelRequested = false;
    final runId = ++_runId;
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    final dio = createDio(receiveTimeout: null);

    // 已有断点：初始进度就是断点大小，续传从这里开始。
    var received = 0;
    final partial = File(savePath);
    if (await partial.exists()) {
      received = await partial.length();
    }
    state = AppUpdateDownloadState(
      status: AppUpdateDownloadStatus.downloading,
      received: received,
      total: -1,
      version: version,
      apkUrl: url,
      expectedSha256: expectedSha256,
    );

    try {
      await ResumableDownloader.download(
        dio,
        url,
        savePath,
        onProgress: (r, t) {
          // 只认当前这一轮的回调，暂停/取消后的迟到回调不更新状态。
          if (runId == _runId &&
              state.status == AppUpdateDownloadStatus.downloading) {
            state = state.copyWith(received: r, total: t);
          }
        },
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        if (_pauseRequested) {
          final current = await partial.exists()
              ? await partial.length()
              : 0;
          state = state.copyWith(
            status: AppUpdateDownloadStatus.paused,
            received: current,
          );
        } else if (_cancelRequested) {
          await _deletePartial(savePath);
          state = const AppUpdateDownloadState();
        } else {
          state = state.copyWith(
            status: AppUpdateDownloadStatus.failed,
            error: AppUpdateDownloadError.download,
          );
        }
      } else {
        state = state.copyWith(
          status: AppUpdateDownloadStatus.failed,
          error: AppUpdateDownloadError.download,
        );
      }
      return;
    } on Object {
      // 内容异常（HTML 墙页、文件头不对、截断）：不断点续传一个坏文件。
      await _deletePartial(savePath);
      state = state.copyWith(
        status: AppUpdateDownloadStatus.failed,
        error: AppUpdateDownloadError.download,
      );
      return;
    } finally {
      dio.close();
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
    }

    // 下载完成：先校验（SHA-256 + 签名），再持久化、自动安装。
    final total = await partial.exists() ? await partial.length() : 0;
    final verification = await AppInstaller.verifyApk(
      path: savePath,
      expectedSha256: expectedSha256,
    );
    if (!verification.verified) {
      await _deletePartial(savePath);
      await AppInstaller.clearDownloadedApk();
      state = state.copyWith(
        status: AppUpdateDownloadStatus.failed,
        received: total,
        total: total,
        error: verification.signatureMatches
            ? AppUpdateDownloadError.verify
            : AppUpdateDownloadError.signature,
      );
      return;
    }
    await AppInstaller.saveDownloadedApk(savePath, version);
    state = state.copyWith(
      status: AppUpdateDownloadStatus.completed,
      received: total,
      total: total,
      apkPath: savePath,
    );
    // 第 15 项：下完自动调起安装；系统不允许时留给用户去设置里允许，
    // 包已持久化，之后点安装不用重新下载。
    await install();
  }

  /// 暂停：取消本次请求，断点留在盘上。
  void pause() {
    if (state.status != AppUpdateDownloadStatus.downloading) return;
    _pauseRequested = true;
    _cancelToken?.cancel();
  }

  /// 继续：从断点续传。
  Future<void> resume() async {
    final url = state.apkUrl;
    final version = state.version;
    if (state.status != AppUpdateDownloadStatus.paused ||
        url == null ||
        version == null) {
      return;
    }
    await start(
      url: url,
      version: version,
      expectedSha256: state.expectedSha256,
    );
  }

  /// 取消：停掉本次请求，删掉断点文件与校验 sidecar，回到 idle。
  Future<void> cancel() async {
    if (state.status == AppUpdateDownloadStatus.paused) {
      final path = state.apkPath ?? await _currentSavePath();
      if (path != null) await _deletePartial(path);
      state = const AppUpdateDownloadState();
      return;
    }
    if (state.status != AppUpdateDownloadStatus.downloading) return;
    _cancelRequested = true;
    _cancelToken?.cancel();
  }

  /// 重新下载（失败后重试）：断点还在就续传，坏文件已由失败路径清掉。
  Future<void> retry() async {
    final url = state.apkUrl;
    final version = state.version;
    if (url == null || version == null) return;
    await start(
      url: url,
      version: version,
      expectedSha256: state.expectedSha256,
    );
  }

  /// 安装已下载好的更新包（第 13、15 项）：安装前再验一次
  /// （文件可能在下载后被换掉），签名不一致拒绝安装。
  /// 系统不允许安装未知应用时返回 false 并置
  /// [AppUpdateDownloadState.needsUnknownSources]，由 UI 引导用户
  /// 去设置里允许；包已持久化，允许后点安装不用重新下载。
  Future<bool> install() async {
    final version = state.version;
    final path = state.apkPath ??
        (version == null
            ? null
            : await AppInstaller.usablePersistedApkFor(version));
    if (path == null || version == null) return false;
    final verification = await AppInstaller.verifyApk(
      path: path,
      expectedSha256: state.expectedSha256,
    );
    if (!verification.verified) {
      await AppInstaller.clearDownloadedApk();
      state = state.copyWith(
        status: AppUpdateDownloadStatus.failed,
        error: verification.signatureMatches
            ? AppUpdateDownloadError.verify
            : AppUpdateDownloadError.signature,
      );
      return false;
    }
    if (!await AppInstaller.canInstallPackages()) {
      state = state.copyWith(needsUnknownSources: true);
      return false;
    }
    state = state.copyWith(needsUnknownSources: false);
    return AppInstaller.installApk(path);
  }

  /// 打开系统“允许安装未知应用”设置页。
  Future<void> openInstallSettings() async {
    await AppInstaller.openUnknownSourcesSettings();
  }

  /// 恢复之前下载好、还留在盘上的安装包（第 13 项）：版本与
  /// [latestVersion] 一致且文件还在时回到完成态，点安装直接装。
  /// 在更新对话框打开前调一次。
  Future<void> refreshPersisted(String latestVersion) async {
    if (state.status != AppUpdateDownloadStatus.idle) return;
    final path = await AppInstaller.usablePersistedApkFor(latestVersion);
    if (path == null) return;
    final size = await File(path).length();
    state = AppUpdateDownloadState(
      status: AppUpdateDownloadStatus.completed,
      received: size,
      total: size,
      version: latestVersion,
      apkPath: path,
    );
  }

  /// 关掉悬浮条（不删文件、不清记录）。
  void dismiss() {
    state = const AppUpdateDownloadState();
  }

  Future<String?> _currentSavePath() async {
    final version = state.version;
    if (version == null) return null;
    return apkSavePath(version);
  }

  static Future<void> _deletePartial(String savePath) async {
    final file = File(savePath);
    if (await file.exists()) {
      try {
        await file.delete();
      } on FileSystemException {
        // 删不掉就留着，下次下载会从断点续传或覆盖。
      }
    }
    final meta = File(ResumableDownloader.metaPathFor(savePath));
    if (await meta.exists()) {
      try {
        await meta.delete();
      } on FileSystemException {
        // 同上。
      }
    }
  }
}

final updateDownloadProvider =
    NotifierProvider<AppUpdateDownloader, AppUpdateDownloadState>(
      AppUpdateDownloader.new,
    );
