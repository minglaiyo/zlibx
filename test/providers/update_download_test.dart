import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zlibx/services/app_install.dart';
import 'package:zlibx/services/app_update_downloader.dart';
import 'package:zlibx/services/hive_service.dart';

/// 应用内更新下载状态机（计划一第 12–15 项）：对一个真实 loopback
/// 服务器跑完整下载 / 暂停续传 / 取消 / 校验失败 / 未允许安装
/// 未知应用 / 已下载包持久化恢复。APK 首包是 PK 头（第 8 项魔数
/// 校验认 apk），服务器按 8KB 分片 + 25ms 间隔流式回包并支持
/// Range，这样暂停/取消在下载中途有窗口可打。
const _channel = MethodChannel('zlibx/app_install');
const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

List<int> _apkBody(int size) {
  final body = List<int>.filled(size, 0x41);
  body[0] = 0x50; // P
  body[1] = 0x4B; // K
  return body;
}

/// 分片慢速源：支持 Range（续传用），每 8KB 停 25ms。
class _SlowOrigin {
  _SlowOrigin(this.body);

  final List<int> body;
  late HttpServer _server;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/zlibx-v1.8.0.apk');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    var start = 0;
    var status = HttpStatus.ok;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'bytes=(\d+)-').firstMatch(range);
      if (match != null) {
        start = int.parse(match.group(1)!);
        status = HttpStatus.partialContent;
      }
    }
    final slice = body.sublist(start);
    final response = request.response
      ..statusCode = status
      ..headers.contentType = ContentType.binary
      ..headers.contentLength = slice.length
      ..headers.set(HttpHeaders.etagHeader, '"v1"');
    if (status == HttpStatus.partialContent) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${body.length - 1}/${body.length}',
      );
    }
    for (var i = 0; i < slice.length; i += 8192) {
      final end = (i + 8192).clamp(0, slice.length);
      response.add(slice.sublist(i, end));
      await response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    await response.close();
  }

  Future<void> stop() async => _server.close(force: true);
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;
  late Directory updatesDir;
  late _SlowOrigin origin;
  late Map<String, dynamic> verifyResult;
  late bool canInstall;
  late List<String> installCalls;

  Map<String, dynamic> goodVerify() => <String, dynamic>{
    'sha256': 'a' * 64,
    'sha256Checked': true,
    'sha256Matches': true,
    'signatureMatches': true,
    'apkFingerprint': 'aa',
    'currentFingerprint': 'aa',
    'error': null,
  };

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('update_download_hive');
    Hive.init(hiveDir.path);
    await Hive.openBox(HiveService.settingsBoxName);
    updatesDir = await Directory.systemTemp.createTemp('update_download_apk');
    // apkSavePath 走 path_provider：外部目录指向临时目录。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
          switch (call.method) {
            case 'getExternalStorageDirectory':
            case 'getApplicationDocumentsDirectory':
              return updatesDir.path;
            default:
              return null;
          }
        });
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir.delete(recursive: true);
    await updatesDir.delete(recursive: true);
  });

  setUp(() async {
    verifyResult = goodVerify();
    canInstall = true;
    installCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          switch (call.method) {
            case 'verifyApk':
              return Map<String, dynamic>.of(verifyResult);
            case 'installApk':
              installCalls.add(call.arguments['path'] as String);
              return true;
            case 'canInstallPackages':
              return canInstall;
            case 'openUnknownSourcesSettings':
              return true;
            default:
              return null;
          }
        });
    // 每个用例干净的 Hive + 干净的 updates 目录。
    final box = HiveService.settingsBox;
    await box.delete('downloadedApkPath');
    await box.delete('downloadedApkVersion');
    for (final entity in updatesDir.listSync()) {
      await entity.delete(recursive: true);
    }
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  AppUpdateDownloader notifier(ProviderContainer c) =>
      c.read(updateDownloadProvider.notifier);

  Future<void> startDownload(
    ProviderContainer c,
    Uri url, {
    String version = '1.8.0',
  }) {
    return notifier(c).start(
      url: url.toString(),
      version: version,
      expectedSha256: 'a' * 64,
    );
  }

  test('完整下载：校验通过 → 持久化 → 自动调起安装', () async {
    origin = _SlowOrigin(_apkBody(4096));
    await origin.start();
    addTearDown(origin.stop);
    final c = container();

    await startDownload(c, origin.url);
    final state = c.read(updateDownloadProvider);
    expect(state.status, AppUpdateDownloadStatus.completed);
    expect(state.received, 4096);
    expect(state.total, 4096);
    final apkPath = await AppUpdateDownloader.apkSavePath('1.8.0');
    expect(File(apkPath).lengthSync(), 4096);
    // 第 13 项：路径 + 版本已持久化。
    expect(await AppInstaller.usablePersistedApkFor('1.8.0'), apkPath);
    // 第 15 项：下完自动调起系统安装。
    expect(installCalls, [apkPath]);
  });

  test('暂停后断点续传：部分文件保留，续传后补满', () async {
    origin = _SlowOrigin(_apkBody(200 * 1024));
    await origin.start();
    addTearDown(origin.stop);
    final c = container();
    final n = notifier(c);

    unawaited(startDownload(c, origin.url));
    await _waitFor(() => c.read(updateDownloadProvider).received > 0);
    n.pause();
    await _waitFor(
      () => c.read(updateDownloadProvider).status ==
          AppUpdateDownloadStatus.paused,
    );
    final apkPath = await AppUpdateDownloader.apkSavePath('1.8.0');
    final partialSize = File(apkPath).lengthSync();
    expect(partialSize, greaterThan(0));
    expect(partialSize, lessThan(200 * 1024));

    await n.resume();
    await _waitFor(
      () => c.read(updateDownloadProvider).status ==
          AppUpdateDownloadStatus.completed,
    );
    expect(File(apkPath).lengthSync(), 200 * 1024);
  });

  test('取消：回到 idle，部分文件删掉', () async {
    origin = _SlowOrigin(_apkBody(200 * 1024));
    await origin.start();
    addTearDown(origin.stop);
    final c = container();
    final n = notifier(c);

    unawaited(startDownload(c, origin.url));
    await _waitFor(() => c.read(updateDownloadProvider).received > 0);
    await n.cancel();
    await _waitFor(
      () =>
          c.read(updateDownloadProvider).status ==
          AppUpdateDownloadStatus.idle,
    );
    expect(
      File(await AppUpdateDownloader.apkSavePath('1.8.0')).existsSync(),
      isFalse,
    );
    expect(installCalls, isEmpty);
  });

  test('sha256 不匹配：失败，error 为 verify，不调安装', () async {
    origin = _SlowOrigin(_apkBody(4096));
    await origin.start();
    addTearDown(origin.stop);
    verifyResult['sha256Matches'] = false;
    final c = container();

    await startDownload(c, origin.url);
    final state = c.read(updateDownloadProvider);
    expect(state.status, AppUpdateDownloadStatus.failed);
    expect(state.error, AppUpdateDownloadError.verify);
    expect(installCalls, isEmpty);
    expect(await AppInstaller.usablePersistedApkFor('1.8.0'), isNull);
  });

  test('签名不一致：失败，error 为 signature，不调安装', () async {
    origin = _SlowOrigin(_apkBody(4096));
    await origin.start();
    addTearDown(origin.stop);
    verifyResult['signatureMatches'] = false;
    final c = container();

    await startDownload(c, origin.url);
    final state = c.read(updateDownloadProvider);
    expect(state.status, AppUpdateDownloadStatus.failed);
    expect(state.error, AppUpdateDownloadError.signature);
    expect(installCalls, isEmpty);
  });

  test('未允许安装未知应用：下完不调安装，标记 needsUnknownSources', () async {
    origin = _SlowOrigin(_apkBody(4096));
    await origin.start();
    addTearDown(origin.stop);
    canInstall = false;
    final c = container();

    await startDownload(c, origin.url);
    final state = c.read(updateDownloadProvider);
    expect(state.status, AppUpdateDownloadStatus.completed);
    expect(state.needsUnknownSources, isTrue);
    expect(installCalls, isEmpty);
    // 包已持久化，允许后重点安装不用重新下载。
    expect(await AppInstaller.usablePersistedApkFor('1.8.0'), isNotNull);
  });

  test('refreshPersisted：之前下好的包在，恢复为 completed', () async {
    final c = container();
    final n = notifier(c);
    final apkPath = await AppUpdateDownloader.apkSavePath('1.8.0');
    await File(apkPath).writeAsBytes(_apkBody(1024));
    await AppInstaller.saveDownloadedApk(apkPath, '1.8.0');

    await n.refreshPersisted('1.8.0');
    final state = c.read(updateDownloadProvider);
    expect(state.status, AppUpdateDownloadStatus.completed);
    expect(state.apkPath, apkPath);

    // 版本不符：不恢复。
    final c2 = container();
    await c2.read(updateDownloadProvider.notifier).refreshPersisted('9.9.9');
    expect(
      c2.read(updateDownloadProvider).status,
      AppUpdateDownloadStatus.idle,
    );
  });
}
