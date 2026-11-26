import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:hive/hive.dart';

import '../utils/diagnostics.dart';
import '../utils/json_utils.dart';
import 'external_download.dart';
import 'hive_service.dart';
import 'secure_storage.dart';

/// 完整备份与恢复（计划一第 17 项）。
///
/// 导出：5 个 Hive box 全量序列化成带格式版本号的 JSON，打一个 zip；
/// 敏感字段（登录会话 5 个 key + Anna 捐赠 key）单独放进一个用用户密码
/// 加密的信封文件，绝不明文进包。进行中的下载只存在内存和 `.part`
/// sidecar 里，不在任何 box 里，所以天然不在备份里；书本身在公共
/// `Download/zlibx/` 里，也不备份。
///
/// 导入：先校验 zip、格式、版本，再解密（密码错了在写任何东西之前就
/// 报错，不做部分恢复），最后把各 box 整盒替换、敏感字段按备份里的状态
/// 恢复。恢复完必须重启应用（内存里的 provider 还拿着旧状态）。
///
/// 格式（zip 内）：
/// * `backup.json`：`{"format": "zlibx-backup", "version": 1,
///   "exportedAt": "ISO 8601 UTC", "boxes": {"settings": {...},
///   "library": {...}, "auth": {...}, "view_history": {...},
///   "booklist_html": {...}}}`。
/// * `secrets.json.enc`（仅当导出时存在敏感字段）：JSON 信封
///   `{"kdf": "pbkdf2-sha256", "iterations": 100000, "salt": "base64",
///   "nonce": "base64", "ciphertext": "base64", "mac": "base64"}`，
///   明文是 `{"remix_userid": "...", ...}` 的 JSON。
///   密钥 = PBKDF2-HMAC-SHA256（100000 轮，256 位），密文 = AES-256-GCM。
///   100000 轮是纯 Dart 回退时的速度与离线文件威胁模型之间的折中
///   （main 里接了 cryptography_flutter 后走原生 javax.crypto，会快得多）；
///   老版本备份的迁移口子在 [_readManifest] 的 version switch 里。
class BackupRestoreService {
  BackupRestoreService({SecretStore? secretStore, BackupBoxes? boxes})
      : _secrets = secretStore ?? SecureSecretStore(),
        _boxes = boxes;

  final SecretStore _secrets;
  final BackupBoxes? _boxes;

  /// 备份格式标识，写进 `backup.json` 的 `format` 字段。
  static const String kBackupFormat = 'zlibx-backup';

  /// 当前备份格式版本。导入时只认这个版本；高于它的拒绝，低于它的
  /// 走 [_readManifest] 里的迁移分支（现在只有 v1）。
  static const int kBackupFormatVersion = 1;

  /// 导入时接受的备份文件上限。书单缓存 20 MB + 各 box 的量级，
  /// 64 MB 绰绰有余；超了直接拒绝，免得解 zip 时把内存撑爆。
  static const int kBackupMaxBytes = 64 * 1024 * 1024;

  /// PBKDF2 轮数（见类注释）。
  static const int kPbkdf2Iterations = 100000;

  static const String _manifestFileName = 'backup.json';
  static const String _secretsFileName = 'secrets.json.enc';

  /// 敏感字段的 SecureStorage 键（键名出处见 auth_storage.dart 的
  /// `_keyUserId` 等私有常量和 external_download.dart 的
  /// `annasDonationKeySecureKey`）。密码永不落盘，不在这里出现。
  static const List<String> secretKeys = <String>[
    'remix_userid',
    'remix_userkey',
    'user_email',
    'user_name',
    'saved_accounts',
    annasDonationKeySecureKey,
  ];

  /// auth box 里与敏感字段同源的旧键：恢复时如果备份带了 secrets
  /// 信封，这些键一律跳过（信封里的才是最新状态；旧明文密码和已下线
  /// 的后端栈孤儿键更不能留）。键名出处见 auth_storage.dart。
  static const Set<String> _authBoxSecretKeys = <String>{
    'remix_userid',
    'remix_userkey',
    'user_email',
    'user_name',
    'saved_accounts',
    'user_password',
    'backend_jwt',
    'backend_user_id',
    'backend_unionid',
    'backend_last_authorized_at',
    'backend_role',
    'backend_device_id',
  };

  /// settings box 里的旧 Anna key 明文键：导出时剥离、导入时跳过，
  /// 真值只走 secrets 信封（readAnnasDonationKey 读时已做迁移）。
  static const String _legacyAnnasKey = 'annasDonationKey';

  Future<BackupBoxes> get _resolvedBoxes async =>
      _boxes ?? BackupBoxes.live();

  /// 是否存有任何敏感字段（登录会话或 Anna key）。有则导出必须设密码。
  Future<bool> hasSecrets() async {
    for (final String key in secretKeys) {
      final String? value = await _secrets.read(key);
      if (value != null && value.isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  /// 导出备份，返回 zip 字节。调用方写临时文件后走系统分享。
  ///
  /// [password] 只在存在敏感字段时必填（缺了抛
  /// [BackupPasswordRequiredException]）；没有敏感字段时传了也忽略，
  /// 包里不会多出 secrets 文件。
  Future<Uint8List> exportBackup({String? password}) async {
    final BackupBoxes boxes = await _resolvedBoxes;
    final Map<String, String> secrets = await _readSecrets();
    if (secrets.isNotEmpty && (password == null || password.isEmpty)) {
      throw const BackupPasswordRequiredException();
    }

    final Map<String, dynamic> manifest = <String, dynamic>{
      'format': kBackupFormat,
      'version': kBackupFormatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'boxes': <String, dynamic>{
        HiveService.settingsBoxName:
            await _dumpBox(boxes.settings, skipKeys: <String>{_legacyAnnasKey}),
        HiveService.libraryBoxName: await _dumpBox(boxes.library),
        HiveService.authBoxName: await _dumpBox(boxes.auth),
        HiveService.viewHistoryBoxName: await _dumpBox(boxes.viewHistory),
        HiveService.booklistHtmlBoxName:
            await _dumpLazyBox(boxes.booklistHtml),
      },
    };

    final Archive archive = Archive();
    final List<int> manifestBytes =
        utf8.encode(jsonEncode(manifest));
    archive.addFile(
      ArchiveFile(_manifestFileName, manifestBytes.length, manifestBytes),
    );
    if (secrets.isNotEmpty) {
      final Map<String, dynamic> envelope =
          await _encryptSecrets(password!, secrets);
      final List<int> envelopeBytes =
          utf8.encode(jsonEncode(envelope));
      archive.addFile(
        ArchiveFile(_secretsFileName, envelopeBytes.length, envelopeBytes),
      );
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// 只看不写：校验 zip、格式、版本，汇报是否带 secrets 信封。
  /// 导入前用它决定要不要先问用户要密码。
  Future<BackupInfo> peekBackup(Uint8List bytes) async {
    final Archive archive = _decodeZip(bytes);
    final Map<String, dynamic> manifest = await _readManifest(archive);
    final DateTime? exportedAt = _parseExportedAt(manifest['exportedAt']);
    return BackupInfo(
      version: manifest['version'] as int,
      exportedAt: exportedAt,
      hasSecrets: archive.findFile(_secretsFileName) != null,
    );
  }

  /// 导入备份：校验 → 解密 → 写回各 box 与敏感字段。
  ///
  /// 密码只在备份带 secrets 信封时必填；密码错了抛
  /// [BackupWrongPasswordException]，且此时一个字节都没写。其他
  /// 校验失败抛 [BackupInvalidFileException] /
  /// [BackupUnsupportedVersionException] / [BackupTooLargeException]。
  /// 写回是整盒替换（clear + putAll）；备份没带 secrets 信封时，
  /// 本机的敏感字段原样不动。
  Future<void> importBackup(Uint8List bytes, {String? password}) async {
    final Archive archive = _decodeZip(bytes);
    final Map<String, dynamic> manifest = await _readManifest(archive);
    final Map<String, Map<String, dynamic>> boxData =
        _readBoxData(manifest);

    // 先解密（失败就停在这里，什么都不写），再写回。
    Map<String, String>? secrets;
    final ArchiveFile? secretsFile = archive.findFile(_secretsFileName);
    if (secretsFile != null) {
      if (password == null || password.isEmpty) {
        throw const BackupPasswordRequiredException();
      }
      secrets = await _decryptSecrets(password, _fileBytes(secretsFile));
    }

    final BackupBoxes boxes = await _resolvedBoxes;
    await _restoreBox(
      boxes.settings,
      boxData[HiveService.settingsBoxName],
      skipKeys: <String>{_legacyAnnasKey},
    );
    await _restoreBox(boxes.library, boxData[HiveService.libraryBoxName]);
    await _restoreBox(
      boxes.auth,
      boxData[HiveService.authBoxName],
      skipKeys: secrets == null ? null : _authBoxSecretKeys,
    );
    await _restoreBox(
      boxes.viewHistory,
      boxData[HiveService.viewHistoryBoxName],
    );
    await _restoreLazyBox(
      boxes.booklistHtml,
      boxData[HiveService.booklistHtmlBoxName],
    );

    if (secrets != null) {
      await _writeSecrets(secrets);
    }
  }

  Archive _decodeZip(Uint8List bytes) {
    if (bytes.length > kBackupMaxBytes) {
      throw const BackupTooLargeException();
    }
    try {
      return ZipDecoder().decodeBytes(bytes);
    } on Object catch (error) {
      logIgnored('backup_decode_zip', error);
      throw const BackupInvalidFileException();
    }
  }

  /// 读并校验 manifest：格式标识、版本号（迁移口子）、boxes 结构。
  /// 返回的 manifest 是解码后的 JSON 对象。
  Future<Map<String, dynamic>> _readManifest(Archive archive) async {
    final ArchiveFile? manifestFile = archive.findFile(_manifestFileName);
    if (manifestFile == null) {
      throw const BackupInvalidFileException();
    }
    final Object? decoded;
    try {
      decoded = await decodeJsonMaybeIsolate(
        utf8.decode(_fileBytes(manifestFile)),
      );
    } on Object catch (error) {
      logIgnored('backup_manifest_json', error);
      throw const BackupInvalidFileException();
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BackupInvalidFileException();
    }
    if (decoded['format'] != kBackupFormat) {
      throw const BackupInvalidFileException();
    }
    final Object? version = decoded['version'];
    if (version is! int) {
      throw const BackupInvalidFileException();
    }
    // 迁移口子：以后出 v2 时在这里把旧 manifest 就地升到当前版，
    // 再往下走同一套恢复流程；现在只有 v1。
    switch (version) {
      case kBackupFormatVersion:
        break;
      case < kBackupFormatVersion:
        throw const BackupInvalidFileException();
      default:
        throw BackupUnsupportedVersionException(version);
    }
    if (decoded['boxes'] is! Map<String, dynamic>) {
      throw const BackupInvalidFileException();
    }
    return decoded;
  }

  Map<String, Map<String, dynamic>> _readBoxData(
    Map<String, dynamic> manifest,
  ) {
    final Map<String, dynamic> raw =
        manifest['boxes'] as Map<String, dynamic>;
    final Map<String, Map<String, dynamic>> out =
        <String, Map<String, dynamic>>{};
    for (final MapEntry<String, dynamic> entry in raw.entries) {
      if (entry.value is! Map<String, dynamic>) {
        throw const BackupInvalidFileException();
      }
      out[entry.key] = entry.value as Map<String, dynamic>;
    }
    return out;
  }

  DateTime? _parseExportedAt(Object? value) {
    if (value is! String) {
      return null;
    }
    return DateTime.tryParse(value);
  }

  List<int> _fileBytes(ArchiveFile file) {
    return file.content;
  }

  Future<Map<String, String>> _readSecrets() async {
    final Map<String, String> out = <String, String>{};
    for (final String key in secretKeys) {
      final String? value = await _secrets.read(key);
      if (value != null && value.isNotEmpty) {
        out[key] = value;
      }
    }
    return out;
  }

  /// 写回敏感字段：备份里有的写，备份里没有的删（备份即导出时的完整
  /// 状态）。只在备份带 secrets 信封时调用。
  Future<void> _writeSecrets(Map<String, String> secrets) async {
    for (final String key in secretKeys) {
      final String? value = secrets[key];
      if (value == null) {
        await _secrets.delete(key);
      } else {
        await _secrets.write(key, value);
      }
    }
  }

  Future<Map<String, dynamic>> _dumpBox(
    Box<dynamic> box, {
    Set<String>? skipKeys,
  }) async {
    final Map<String, dynamic> out = <String, dynamic>{};
    for (final Object? key in box.keys) {
      if (key is! String) {
        continue;
      }
      if (skipKeys != null && skipKeys.contains(key)) {
        continue;
      }
      final Object? value = _jsonSafe(box.get(key));
      if (identical(value, _unserializable)) {
        // Hive 专有类型进不了 JSON，静默跳过该条（不记日志：值可能是
        // 任意类型，记键名没有诊断价值）。
        continue;
      }
      out[key] = value;
    }
    return out;
  }

  Future<Map<String, dynamic>> _dumpLazyBox(LazyBox<dynamic> box) async {
    final Map<String, dynamic> out = <String, dynamic>{};
    for (final Object? key in box.keys) {
      if (key is! String) {
        continue;
      }
      final Object? value = _jsonSafe(await box.get(key));
      if (identical(value, _unserializable)) {
        continue;
      }
      out[key] = value;
    }
    return out;
  }

  Future<void> _restoreBox(
    Box<dynamic> box,
    Map<String, dynamic>? data, {
    Set<String>? skipKeys,
  }) async {
    await box.clear();
    if (data == null) {
      return;
    }
    final Map<String, dynamic> entries = <String, dynamic>{};
    for (final MapEntry<String, dynamic> entry in data.entries) {
      if (skipKeys != null && skipKeys.contains(entry.key)) {
        continue;
      }
      entries[entry.key] = entry.value;
    }
    if (entries.isNotEmpty) {
      await box.putAll(entries);
    }
  }

  Future<void> _restoreLazyBox(
    LazyBox<dynamic> box,
    Map<String, dynamic>? data,
  ) async {
    await box.clear();
    if (data == null) {
      return;
    }
    for (final MapEntry<String, dynamic> entry in data.entries) {
      await box.put(entry.key, entry.value);
    }
  }

  /// 把 Hive 值转成 JSON 安全的形式；碰到 Hive 专有类型
  /// （如自定义对象）返回 [_unserializable]，调用方跳过该条。
  /// Map 的键一律转字符串（JSON 对象键只能是字符串）。
  Object? _jsonSafe(Object? value) {
    if (value == null ||
        value is String ||
        value is num ||
        value is bool) {
      return value;
    }
    if (value is List<dynamic>) {
      final List<Object?> out = <Object?>[];
      for (final Object? element in value) {
        final Object? safe = _jsonSafe(element);
        if (!identical(safe, _unserializable)) {
          out.add(safe);
        }
      }
      return out;
    }
    if (value is Map<dynamic, dynamic>) {
      final Map<String, dynamic> out = <String, dynamic>{};
      for (final MapEntry<Object?, Object?> entry in value.entries) {
        final Object? safe = _jsonSafe(entry.value);
        if (!identical(safe, _unserializable)) {
          out['${entry.key}'] = safe;
        }
      }
      return out;
    }
    return _unserializable;
  }

  /// 加密 secrets：PBKDF2 派生密钥 + AES-256-GCM，KDF 和加密都放
  /// isolate 里跑（纯 Dart 的 PBKDF2 不便宜，别堵 UI 线程）。
  Future<Map<String, dynamic>> _encryptSecrets(
    String password,
    Map<String, String> secrets,
  ) async {
    final List<int> plaintext = utf8.encode(jsonEncode(secrets));
    final List<int> salt = _randomBytes(16);
    // 盐和 nonce 都在 isolate 外生成：传进 Isolate.run 的闭包只能捕获
    // 可跨 isolate 传递的值（String / List<int>），不能调实例方法。
    final List<int> nonce = _randomBytes(12);
    return Isolate.run(() async {
      final Pbkdf2 pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: kPbkdf2Iterations,
        bits: 256,
      );
      final SecretKey key = await pbkdf2.deriveKeyFromPassword(
        password: password,
        nonce: salt,
      );
      final SecretBox secretBox = await AesGcm.with256bits().encrypt(
        plaintext,
        secretKey: key,
        nonce: nonce,
      );
      return <String, dynamic>{
        'kdf': 'pbkdf2-sha256',
        'iterations': kPbkdf2Iterations,
        'salt': base64Encode(salt),
        'nonce': base64Encode(secretBox.nonce),
        'ciphertext': base64Encode(secretBox.cipherText),
        'mac': base64Encode(secretBox.mac.bytes),
      };
    });
  }

  /// 解密 secrets 信封。密码错（MAC 校验失败）抛
  /// [BackupWrongPasswordException]（isolate 里只返回 null，异常对象
  /// 不跨 isolate 传，方法在这里转抛）；信封本身缺字段或 base64 坏了
  /// 抛 [BackupInvalidFileException]。
  Future<Map<String, String>> _decryptSecrets(
    String password,
    List<int> envelopeBytes,
  ) async {
    final Object? decoded;
    try {
      decoded = await decodeJsonMaybeIsolate(utf8.decode(envelopeBytes));
    } on Object catch (error) {
      logIgnored('backup_secrets_json', error);
      throw const BackupInvalidFileException();
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BackupInvalidFileException();
    }
    if (decoded['kdf'] != 'pbkdf2-sha256') {
      throw const BackupInvalidFileException();
    }
    final Object? iterations = decoded['iterations'];
    if (iterations is! int || iterations <= 0 || iterations > 1000000) {
      throw const BackupInvalidFileException();
    }
    final List<int> salt = _b64(decoded['salt']);
    final List<int> nonce = _b64(decoded['nonce']);
    final List<int> ciphertext = _b64(decoded['ciphertext']);
    final List<int> mac = _b64(decoded['mac']);
    final List<int>? plaintext = await Isolate.run(() async {
      final Pbkdf2 pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: 256,
      );
      final SecretKey key = await pbkdf2.deriveKeyFromPassword(
        password: password,
        nonce: salt,
      );
      final SecretBox secretBox =
          SecretBox(ciphertext, nonce: nonce, mac: Mac(mac));
      try {
        return await AesGcm.with256bits().decrypt(
          secretBox,
          secretKey: key,
        );
      } on SecretBoxAuthenticationError {
        // MAC 对不上 = 密码错（或文件被改过）；在 isolate 里只返回
        // null，异常对象不跨 isolate 传。
        return null;
      }
    });
    if (plaintext == null) {
      throw const BackupWrongPasswordException();
    }
    final Object? secretsJson;
    try {
      secretsJson =
          await decodeJsonMaybeIsolate(utf8.decode(plaintext));
    } on Object catch (error) {
      logIgnored('backup_secrets_plaintext', error);
      throw const BackupInvalidFileException();
    }
    if (secretsJson is! Map<String, dynamic>) {
      throw const BackupInvalidFileException();
    }
    final Map<String, String> out = <String, String>{};
    for (final MapEntry<String, dynamic> entry in secretsJson.entries) {
      if (entry.value is String) {
        out[entry.key] = entry.value as String;
      }
    }
    return out;
  }

  List<int> _b64(Object? value) {
    if (value is! String) {
      throw const BackupInvalidFileException();
    }
    try {
      return base64Decode(value);
    } on Object catch (error) {
      logIgnored('backup_secrets_b64', error);
      throw const BackupInvalidFileException();
    }
  }

  List<int> _randomBytes(int length) {
    final Random random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}

/// [_unserializable] 是 [_BackupRestoreService._jsonSafe] 的哨兵值。
final Object _unserializable = Object();

/// [BackupRestoreService] 要读写的 5 个 box。
class BackupBoxes {
  const BackupBoxes({
    required this.settings,
    required this.library,
    required this.auth,
    required this.viewHistory,
    required this.booklistHtml,
  });

  final Box<dynamic> settings;
  final Box<dynamic> library;
  final Box<dynamic> auth;
  final Box<dynamic> viewHistory;
  final LazyBox<dynamic> booklistHtml;

  /// 生产环境入口：各 box 正常已由 HiveService.init 开好，
  /// 没开的在这里补开（恢复入口在设置页，理论上不会走到补开）。
  static Future<BackupBoxes> live() async {
    if (!Hive.isBoxOpen(HiveService.settingsBoxName)) {
      await Hive.openBox<dynamic>(HiveService.settingsBoxName);
    }
    if (!Hive.isBoxOpen(HiveService.libraryBoxName)) {
      await Hive.openBox<dynamic>(HiveService.libraryBoxName);
    }
    if (!Hive.isBoxOpen(HiveService.authBoxName)) {
      await Hive.openBox<dynamic>(HiveService.authBoxName);
    }
    if (!Hive.isBoxOpen(HiveService.viewHistoryBoxName)) {
      await Hive.openBox<dynamic>(HiveService.viewHistoryBoxName);
    }
    if (!Hive.isBoxOpen(HiveService.booklistHtmlBoxName)) {
      await Hive.openLazyBox<dynamic>(HiveService.booklistHtmlBoxName);
    }
    return BackupBoxes(
      settings: Hive.box<dynamic>(HiveService.settingsBoxName),
      library: Hive.box<dynamic>(HiveService.libraryBoxName),
      auth: Hive.box<dynamic>(HiveService.authBoxName),
      viewHistory: Hive.box<dynamic>(HiveService.viewHistoryBoxName),
      booklistHtml:
          Hive.lazyBox<dynamic>(HiveService.booklistHtmlBoxName),
    );
  }
}

/// [BackupRestoreService.peekBackup] 的结果：只读，不写任何东西。
class BackupInfo {
  const BackupInfo({
    required this.version,
    required this.exportedAt,
    required this.hasSecrets,
  });

  /// 备份的格式版本（当前只认 1）。
  final int version;

  /// 备份的导出时间（manifest 里没有或解析失败时为 null）。
  final DateTime? exportedAt;

  /// 是否带加密的 secrets 信封（带则导入要先问密码）。
  final bool hasSecrets;
}

/// 敏感字段的读写口。默认走 SecureStorage（登录会话）+
/// readAnnasDonationKey/saveAnnasDonationKey（Anna key，含旧 Hive
/// 键迁移）；测试时注入内存实现，免得碰平台 channel。
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSecretStore implements SecretStore {
  @override
  Future<String?> read(String key) async {
    if (key == annasDonationKeySecureKey) {
      final String value = await readAnnasDonationKey();
      return value.isEmpty ? null : value;
    }
    return SecureStorage.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (key == annasDonationKeySecureKey) {
      await saveAnnasDonationKey(value);
      return;
    }
    await SecureStorage.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    if (key == annasDonationKeySecureKey) {
      // 空值即删除（saveAnnasDonationKey 的约定）。
      await saveAnnasDonationKey('');
      return;
    }
    await SecureStorage.delete(key);
  }
}

/// 备份/恢复错误的基类。
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => 'BackupException: $message';
}

/// 不是备份文件：zip 解不开、没有 manifest、格式标识不对、结构坏了。
class BackupInvalidFileException extends BackupException {
  const BackupInvalidFileException()
      : super('not a valid zlibx backup file');
}

/// 备份的格式版本高于当前支持的版本。
class BackupUnsupportedVersionException extends BackupException {
  const BackupUnsupportedVersionException(this.version)
      : super('unsupported backup version: $version');

  final int version;
}

/// 密码错（secrets 信封的 MAC 校验失败）。此时什么都没写。
class BackupWrongPasswordException extends BackupException {
  const BackupWrongPasswordException() : super('wrong backup password');
}

/// 备份带敏感字段，但调用方没给密码（或给了空密码）。
class BackupPasswordRequiredException extends BackupException {
  const BackupPasswordRequiredException()
      : super('backup contains secrets but no password was given');
}

/// 备份文件超过 [BackupRestoreService.kBackupMaxBytes]。
class BackupTooLargeException extends BackupException {
  const BackupTooLargeException() : super('backup file is too large');
}
