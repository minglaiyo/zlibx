import 'dart:convert';

import '../utils/diagnostics.dart';
import 'hive_service.dart';
import 'secure_storage.dart';

/// Account credentials at rest.
///
/// Session keys (`remix_userid` / `remix_userkey`), profile fields and the
/// saved-accounts list live in [SecureStorage] (Android Keystore /
/// iOS Keychain), NEVER in the plaintext Hive boxes.
///
/// Passwords are never persisted: login needs the password only for the
/// request itself, and account switching re-uses the stored session keys
/// via `loginWithToken`. Any password found in the legacy Hive box is
/// deleted during migration, not carried over.
class AuthStorage {
  static const String _keyUserId = 'remix_userid';
  static const String _keyUserKey = 'remix_userkey';
  static const String _keyUserEmail = 'user_email';
  static const String _keyUserName = 'user_name';
  static const String _keyAccounts = 'saved_accounts';

  // Legacy plaintext Hive keys, deleted by migration (password included).
  static const String _legacyKeyPassword = 'user_password';

  // Removed AI/backend feature's legacy Hive keys: the whole backend
  // auth stack is gone, so its orphaned token must not linger either.
  static const _legacyBackendKeys = [
    'backend_jwt',
    'backend_user_id',
    'backend_unionid',
    'backend_last_authorized_at',
    'backend_role',
    'backend_device_id',
  ];

  static Future<void>? _migration;

  /// One-time move of legacy plaintext Hive credentials into secure
  /// storage. Single-flight: concurrent callers all await the same run, so
  /// nobody reads an empty secure store while the move is in progress. On
  /// failure the legacy data is left untouched and the next call retries.
  Future<void> _migrateLegacyIfNeeded() {
    return _migration ??= _runMigration().catchError((Object e, StackTrace s) {
      _migration = null;
      Error.throwWithStackTrace(e, s);
    });
  }

  Future<void> _runMigration() async {
    final box = HiveService.authBox;
    final hasLegacy = box.containsKey(_keyUserId) ||
        box.containsKey(_keyUserKey) ||
        box.containsKey(_keyAccounts) ||
        box.containsKey(_legacyKeyPassword) ||
        _legacyBackendKeys.any((key) => box.containsKey(key));
    if (!hasLegacy) return;

    final userId = box.get(_keyUserId) as String?;
    final userKey = box.get(_keyUserKey) as String?;
    final email = box.get(_keyUserEmail) as String?;
    final name = box.get(_keyUserName) as String?;
    if (userId != null) await SecureStorage.write(_keyUserId, userId);
    if (userKey != null) await SecureStorage.write(_keyUserKey, userKey);
    if (email != null) await SecureStorage.write(_keyUserEmail, email);
    if (name != null) await SecureStorage.write(_keyUserName, name);

    // Saved accounts: same entries minus passwords.
    String? accountsJson;
    final rawAccounts = box.get(_keyAccounts, defaultValue: []);
    if (rawAccounts is List && rawAccounts.isNotEmpty) {
      final cleaned = rawAccounts.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        m.remove('password');
        return m;
      }).toList();
      accountsJson = jsonEncode(cleaned);
      await SecureStorage.write(_keyAccounts, accountsJson);
    }

    // Read everything back before touching the legacy copy: if secure
    // storage silently failed, keep the old data and retry next time.
    if ((userId != null && await SecureStorage.read(_keyUserId) != userId) ||
        (userKey != null &&
            await SecureStorage.read(_keyUserKey) != userKey) ||
        (accountsJson != null &&
            await SecureStorage.read(_keyAccounts) != accountsJson)) {
      throw StateError('secure storage write verification failed');
    }

    // Delete every legacy plaintext key, password included, plus the
    // removed backend-auth stack's orphaned keys.
    await box.delete(_keyUserId);
    await box.delete(_keyUserKey);
    await box.delete(_keyUserEmail);
    await box.delete(_keyUserName);
    await box.delete(_legacyKeyPassword);
    await box.delete(_keyAccounts);
    for (final key in _legacyBackendKeys) {
      await box.delete(key);
    }
    // Hive only appends: without compaction the deleted plaintext values
    // stay readable in the box file.
    await box.compact();
  }

  /// Save authentication credentials (session keys only — no password).
  Future<void> saveCredentials({
    required String userId,
    required String userKey,
    String? email,
    String? name,
  }) async {
    await _migrateLegacyIfNeeded();
    await SecureStorage.write(_keyUserId, userId);
    await SecureStorage.write(_keyUserKey, userKey);
    if (email != null) await SecureStorage.write(_keyUserEmail, email);
    if (name != null) await SecureStorage.write(_keyUserName, name);

    // Also save to accounts list (without password).
    await saveAccount({
      'userId': userId,
      'userKey': userKey,
      'email': email,
      'name': name,
    });
  }

  /// Retrieve stored credentials.
  Future<Map<String, String?>> getCredentials() async {
    await _migrateLegacyIfNeeded();
    return {
      'userId': await SecureStorage.read(_keyUserId),
      'userKey': await SecureStorage.read(_keyUserKey),
      'email': await SecureStorage.read(_keyUserEmail),
      'name': await SecureStorage.read(_keyUserName),
    };
  }

  /// Clear all stored credentials, including the saved-accounts list:
  /// after logout nothing that can log back in may remain on disk.
  Future<void> clearCredentials() async {
    await _migrateLegacyIfNeeded();
    await SecureStorage.delete(_keyUserId);
    await SecureStorage.delete(_keyUserKey);
    await SecureStorage.delete(_keyUserEmail);
    await SecureStorage.delete(_keyUserName);
    await SecureStorage.delete(_keyAccounts);
  }

  /// Serializes the saved-accounts read-modify-write cycles (save /
  /// remove): two interleaved runs would each read the old list and
  /// the second write would silently drop the first's change. The
  /// chain never stays broken — an action's error is rethrown to ITS
  /// caller but swallowed for the chain itself.
  Future<void>? _accountsWriteChain;

  Future<T> _serializeAccountsWrite<T>(Future<T> Function() action) {
    final run =
        (_accountsWriteChain ?? Future<void>.value()).then((_) => action());
    _accountsWriteChain =
        run.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return run;
  }

  /// Save an account to the list (session keys only — no password).
  Future<void> saveAccount(Map<String, dynamic> account) {
    return _serializeAccountsWrite(() async {
      await _migrateLegacyIfNeeded();
      final accounts = await getStoredAccounts();
      final existingIndex = accounts.indexWhere(
        (a) => a['userId'] == account['userId'],
      );
      if (existingIndex != -1) {
        accounts.removeAt(existingIndex);
      }
      // Keep the most recently used account at the end of the list.
      final entry = Map<String, dynamic>.from(account)..remove('password');
      accounts.add(entry);
      // Each entry carries a session key that can re-login the account.
      // Copies accumulate forever otherwise — cap the list and drop the
      // LEAST recently used entries (front of the MRU-ordered list).
      const maxSavedAccounts = 8;
      while (accounts.length > maxSavedAccounts) {
        accounts.removeAt(0);
      }
      await SecureStorage.write(_keyAccounts, jsonEncode(accounts));
    });
  }

  /// Get all stored accounts.
  Future<List<Map<dynamic, dynamic>>> getStoredAccounts() async {
    await _migrateLegacyIfNeeded();
    final raw = await SecureStorage.read(_keyAccounts);
    if (raw == null || raw.isEmpty) return [];
    // Corrupted stored content (truncated write, Keystore churn) must not
    // break login / account switching: report and start over empty.
    final List<dynamic> decoded;
    try {
      final value = jsonDecode(raw);
      if (value is! List) return [];
      decoded = value;
    } catch (e) {
      logIgnored('auth_storage', e);
      return [];
    }
    return decoded
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => Map<dynamic, dynamic>.from(e))
        .toList();
  }

  /// Remove an account.
  Future<void> removeAccount(String userId) {
    return _serializeAccountsWrite(() async {
      await _migrateLegacyIfNeeded();
      final accounts = await getStoredAccounts();
      accounts.removeWhere((a) => a['userId'] == userId);
      await SecureStorage.write(_keyAccounts, jsonEncode(accounts));
    });
  }
}
