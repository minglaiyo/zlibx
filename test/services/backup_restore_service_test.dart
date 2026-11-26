import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:zlibx/services/backup_restore_service.dart';
import 'package:zlibx/services/hive_service.dart';

/// 完整备份与恢复（计划一第 17 项）：导出→导入往返、密码错误、
/// 版本校验、进行中下载不备份。内存 SecretStore 替掉 SecureStorage，
/// 免得测试碰平台 channel；box 用真 Hive（临时目录），和
/// storage_service_test.dart 同一套路。
void main() {
  late Directory tempDir;
  late _MemorySecretStore secrets;
  late BackupRestoreService service;

  BackupBoxes boxes() => BackupBoxes(
        settings: Hive.box(HiveService.settingsBoxName),
        library: Hive.box(HiveService.libraryBoxName),
        auth: Hive.box(HiveService.authBoxName),
        viewHistory: Hive.box(HiveService.viewHistoryBoxName),
        booklistHtml: Hive.lazyBox(HiveService.booklistHtmlBoxName),
      );

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('backup_restore');
    Hive.init(tempDir.path);
    await Hive.openBox(HiveService.settingsBoxName);
    await Hive.openBox(HiveService.libraryBoxName);
    await Hive.openBox(HiveService.authBoxName);
    await Hive.openBox(HiveService.viewHistoryBoxName);
    await Hive.openLazyBox(HiveService.booklistHtmlBoxName);
  });

  setUp(() async {
    await Hive.box(HiveService.settingsBoxName).clear();
    await Hive.box(HiveService.libraryBoxName).clear();
    await Hive.box(HiveService.authBoxName).clear();
    await Hive.box(HiveService.viewHistoryBoxName).clear();
    await Hive.lazyBox(HiveService.booklistHtmlBoxName).clear();
    secrets = _MemorySecretStore();
    service = BackupRestoreService(secretStore: secrets, boxes: boxes());
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  Future<void> seedBoxes() async {
    await Hive.box(HiveService.settingsBoxName).putAll(<String, dynamic>{
      'theme_mode': 'dark',
      'blockedKeywords': <String>['a', 'b'],
      'downloadOrganizeMode': 1,
    });
    await Hive.box(HiveService.libraryBoxName).putAll(<String, dynamic>{
      'favorite_books_acc1': <String>['1', '2'],
      'dl:1': <String, dynamic>{
        'title': 'Book One',
        'path': '/x.epub',
      },
      'dl_order': <String>['1'],
    });
    await Hive.box(HiveService.authBoxName).putAll(<String, dynamic>{
      'some_auth_flag': true,
      // 旧设备上还没迁移的明文会话键：导出时跟着 box 走，
      // 导入时有 secrets 信封就跳过它。
      'remix_userid': 'legacy-user-id',
    });
    await Hive.box(HiveService.viewHistoryBoxName).putAll(<String, dynamic>{
      'book-1': <String, dynamic>{
        'id': 1,
        'viewedAt': '2026-11-26T00:00:00.000Z',
      },
    });
    await Hive.lazyBox(HiveService.booklistHtmlBoxName).put(
      'https://example.com/list',
      <String, dynamic>{'at': 123, 'html': '<p>x</p>'},
    );
  }

  Future<void> seedSecrets() async {
    await secrets.write('remix_userid', 'user-1');
    await secrets.write('remix_userkey', 'key-1');
    await secrets.write('user_email', 'a@b.c');
    await secrets.write('user_name', 'Name');
    await secrets.write('saved_accounts', '[{"userId":"user-1"}]');
    await secrets.write('annasDonationKey', 'anna-key-123');
  }

  Future<void> clearAll() async {
    await Hive.box(HiveService.settingsBoxName).clear();
    await Hive.box(HiveService.libraryBoxName).clear();
    await Hive.box(HiveService.authBoxName).clear();
    await Hive.box(HiveService.viewHistoryBoxName).clear();
    await Hive.lazyBox(HiveService.booklistHtmlBoxName).clear();
    secrets.values.clear();
  }

  Map<String, dynamic> readManifest(Uint8List bytes) {
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final ArchiveFile? file = archive.findFile('backup.json');
    expect(file, isNotNull);
    final Uint8List content = file!.content;
    expect(content, isA<List<int>>());
    return jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
  }

  test('export then import restores all boxes and secrets', () async {
    await seedBoxes();
    await seedSecrets();

    const String password = 'test-password-123';
    final Uint8List bytes =
        await service.exportBackup(password: password);

    final BackupInfo info = await service.peekBackup(bytes);
    expect(info.version, BackupRestoreService.kBackupFormatVersion);
    expect(info.hasSecrets, isTrue);
    expect(info.exportedAt, isNotNull);

    await clearAll();
    await service.importBackup(bytes, password: password);

    expect(
      Hive.box(HiveService.settingsBoxName).get('theme_mode'),
      'dark',
    );
    expect(
      Hive.box(HiveService.settingsBoxName).get('blockedKeywords'),
      <String>['a', 'b'],
    );
    expect(
      Hive.box(HiveService.libraryBoxName).get('favorite_books_acc1'),
      <String>['1', '2'],
    );
    expect(
      Hive.box(HiveService.libraryBoxName).get('dl:1'),
      <String, dynamic>{'title': 'Book One', 'path': '/x.epub'},
    );
    expect(
      Hive.box(HiveService.authBoxName).get('some_auth_flag'),
      isTrue,
    );
    // auth box 里的旧明文会话键被跳过，不写回。
    expect(
      Hive.box(HiveService.authBoxName).get('remix_userid'),
      isNull,
    );
    expect(
      Hive.box(HiveService.viewHistoryBoxName).get('book-1'),
      <String, dynamic>{'id': 1, 'viewedAt': '2026-11-26T00:00:00.000Z'},
    );
    final Object? cached = await Hive.lazyBox(HiveService.booklistHtmlBoxName)
        .get('https://example.com/list');
    expect(cached, <String, dynamic>{'at': 123, 'html': '<p>x</p>'});
    // 敏感字段走信封，全回来了。
    expect(await secrets.read('remix_userid'), 'user-1');
    expect(await secrets.read('remix_userkey'), 'key-1');
    expect(await secrets.read('user_email'), 'a@b.c');
    expect(await secrets.read('user_name'), 'Name');
    expect(await secrets.read('saved_accounts'), '[{"userId":"user-1"}]');
    expect(await secrets.read('annasDonationKey'), 'anna-key-123');
  });

  test('export without password fails when secrets exist', () async {
    await seedBoxes();
    await seedSecrets();
    await expectLater(
      service.exportBackup(),
      throwsA(isA<BackupPasswordRequiredException>()),
    );
  });

  test('export without secrets needs no password and has no envelope',
      () async {
    await seedBoxes();
    final Uint8List bytes = await service.exportBackup();
    final BackupInfo info = await service.peekBackup(bytes);
    expect(info.hasSecrets, isFalse);
    await clearAll();
    await service.importBackup(bytes);
    expect(
      Hive.box(HiveService.settingsBoxName).get('theme_mode'),
      'dark',
    );
    expect(
      Hive.box(HiveService.libraryBoxName).get('dl:1'),
      <String, dynamic>{'title': 'Book One', 'path': '/x.epub'},
    );
  });

  test('wrong password writes nothing', () async {
    await seedBoxes();
    await seedSecrets();
    final Uint8List bytes =
        await service.exportBackup(password: 'test-password-123');

    // 备份之后本机状态变了：导入必须原样保留这些“当前”值。
    await clearAll();
    await Hive.box(HiveService.settingsBoxName)
        .put('sentinel', 'current-value');
    await secrets.write('remix_userid', 'current-user');

    await expectLater(
      service.importBackup(bytes, password: 'wrong-password'),
      throwsA(isA<BackupWrongPasswordException>()),
    );
    expect(
      Hive.box(HiveService.settingsBoxName).get('sentinel'),
      'current-value',
    );
    expect(
      Hive.box(HiveService.settingsBoxName).get('theme_mode'),
      isNull,
    );
    expect(await secrets.read('remix_userid'), 'current-user');
  });

  test('unsupported version is rejected', () async {
    await seedBoxes();
    final Uint8List bytes = await service.exportBackup();

    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final Archive rebuilt = Archive();
    for (final ArchiveFile file in archive.files) {
      if (!file.isFile) {
        continue;
      }
      final Uint8List content = file.content;
      expect(content, isA<List<int>>());
      if (file.name == 'backup.json') {
        final Map<String, dynamic> manifest =
            jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
        manifest['version'] = 99;
        final List<int> modified =
            utf8.encode(jsonEncode(manifest));
        rebuilt.addFile(ArchiveFile(file.name, modified.length, modified));
      } else {
        final List<int> original = content;
        rebuilt.addFile(
          ArchiveFile(file.name, original.length, original),
        );
      }
    }
    final Uint8List tampered =
        Uint8List.fromList(ZipEncoder().encode(rebuilt));

    await expectLater(
      service.importBackup(tampered),
      throwsA(isA<BackupUnsupportedVersionException>()),
    );
  });

  test('backup covers exactly the five boxes; no in-progress state',
      () async {
    await seedBoxes();
    final Uint8List bytes = await service.exportBackup();
    final Map<String, dynamic> manifest = readManifest(bytes);

    expect(manifest['format'], BackupRestoreService.kBackupFormat);
    expect(manifest['version'], BackupRestoreService.kBackupFormatVersion);
    final Map<String, dynamic> boxData =
        manifest['boxes'] as Map<String, dynamic>;
    // 进行中的下载只存在内存和 `.part` sidecar 里，不在任何 box 里，
    // 所以备份的 box 集合就是这 5 个，不多不少。
    expect(
      boxData.keys.toSet(),
      <String>{
        'settings',
        'library',
        'auth',
        'view_history',
        'booklist_html',
      },
    );
    final Map<String, dynamic> library =
        boxData['library'] as Map<String, dynamic>;
    expect(
      library['dl:1'],
      <String, dynamic>{'title': 'Book One', 'path': '/x.epub'},
    );
  });
}

class _MemorySecretStore implements SecretStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
