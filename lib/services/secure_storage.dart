import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Single place for secrets at rest.
///
/// Android: Keystore-backed RSA-OAEP key wrapping + AES-GCM storage
/// (flutter_secure_storage v11 default; the old `encryptedSharedPreferences`
/// flag was removed in v11.0.0, and the v11 default is its stronger
/// replacement). Anything that can log its owner in — account session keys,
/// bearer tokens — belongs here, NEVER in the plaintext Hive boxes.
/// Non-secret state (settings, caches, download history) stays in Hive.
class SecureStorage {
  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions());

  static Future<String?> read(String key) => _storage.read(key: key);

  static Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  static Future<void> delete(String key) => _storage.delete(key: key);
}
