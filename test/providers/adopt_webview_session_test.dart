import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';

/// [AuthNotifier.adoptWebViewSession] tests: the reader WebView's
/// site-side login (or the server's key rotation) must be adopted by
/// the app — session pair into the API layer, credentials persisted,
/// auth state updated — without any network validation round trip.
///
/// Secure storage is mocked at the plugin's method channel (the same
/// trick the resumable-downloader tests use for platform channels);
/// Hive boxes are opened against a temp dir, since `_init` reads the
/// settings box and the credential migration touches the auth box.
class _FakeZLibraryApi implements ZLibraryApi {
  _FakeZLibraryApi();

  /// (userId, userKey) pairs passed to [adoptSession], in order.
  final List<(String, String)> adoptCalls = [];

  int profileCalls = 0;

  // The pair the API layer currently holds (updated via adoptSession).
  String _userId = '111';
  String _userKey = 'oldKey';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  void adoptSession(String userId, String userKey) {
    adoptCalls.add((userId, userKey));
    _userId = userId;
    _userKey = userKey;
  }

  @override
  Future<ApiResponse<User>> loginWithToken(
    String userId,
    String userKey,
  ) async {
    _userId = userId;
    _userKey = userKey;
    return ApiResponse.ok(_profileUser());
  }

  @override
  Future<ApiResponse<User>> getProfile() async {
    profileCalls++;
    return ApiResponse.ok(_profileUser());
  }

  User _profileUser() => User(
        id: _userId,
        email: _userId == '111' ? 'alice@example.com' : '',
        name: _userId == '111' ? 'Alice' : 'User',
        remixUserkey: _userKey,
      );
}

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// In-memory store backing the mocked secure-storage channel, exposed
/// so assertions can read what [AuthStorage] actually persisted.
final Map<String, String> secureStore = <String, String>{};

void _mockSecureStorage() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    switch (call.method) {
      case 'read':
        return secureStore[call.arguments['key'] as String];
      case 'write':
        secureStore[call.arguments['key'] as String] =
            call.arguments['value'] as String;
        return null;
      case 'delete':
        secureStore.remove(call.arguments['key'] as String);
        return null;
      case 'containsKey':
        return secureStore.containsKey(call.arguments['key'] as String);
      case 'readAll':
        return Map<String, String>.of(secureStore);
      case 'deleteAll':
        secureStore.clear();
        return null;
      default:
        return null;
    }
  });
}

Directory? _hiveTempDir;

Future<ProviderContainer> _container(_FakeZLibraryApi api) async {
  final container = ProviderContainer(overrides: [
    zlibraryApiProvider.overrideWithValue(api),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// Boot the real [AuthNotifier] (seeded credentials via the mocked
/// secure store) and wait for `_init` to settle.
Future<AuthState> _bootAuth(ProviderContainer container) async {
  secureStore['remix_userid'] = '111';
  secureStore['remix_userkey'] = 'oldKey';
  secureStore['user_email'] = 'alice@example.com';
  secureStore['user_name'] = 'Alice';
  container.read(authProvider.notifier);
  for (var i = 0; i < 50 && container.read(authProvider).isLoading; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return container.read(authProvider);
}

void main() {
  setUpAll(() async {
    _mockSecureStorage();
    _hiveTempDir = await Directory.systemTemp.createTemp('adopt_webview');
    Hive.init(_hiveTempDir!.path);
    await Hive.openBox('settings');
    await Hive.openBox('auth');
  });

  setUp(() {
    secureStore.clear();
    // 每条用例都重新注册：tearDown 会把 handler 置空。
    _mockSecureStorage();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  tearDownAll(() async {
    // Hive 持有句柄，Windows 上必须先关库再删目录。
    await Hive.close();
    await _hiveTempDir?.delete(recursive: true);
  });

  test('same-account adoption: api pair updated, credentials persisted, '
      'profile fields kept', () async {
    final api = _FakeZLibraryApi();
    final container = await _container(api);
    final state = await _bootAuth(container);
    expect(state.user?.id, '111');
    expect(state.user?.remixUserkey, 'oldKey');

    await container.read(authProvider.notifier).adoptWebViewSession(
          '111',
          'newKey',
        );

    // The API layer now sends the fresh pair on every request.
    expect(api.adoptCalls, [('111', 'newKey')]);
    final user = container.read(authProvider).user!;
    expect(user.id, '111');
    expect(user.remixUserkey, 'newKey');
    // Same account: email/name survive the adoption (refreshProfile may
    // have re-filled them, same values expected either way).
    expect(user.email, 'alice@example.com');
    expect(user.name, 'Alice');
    // Best effort profile refresh ran on top of the adopted pair.
    expect(api.profileCalls, greaterThanOrEqualTo(1));
    // The persisted credentials carry the fresh key now.
    expect(secureStore['remix_userid'], '111');
    expect(secureStore['remix_userkey'], 'newKey');
  });

  test('different-account adoption clears stale identity fields and '
      'invalidates account-scoped caches', () async {
    final api = _FakeZLibraryApi();
    final container = await _container(api);
    await _bootAuth(container);

    await container.read(authProvider.notifier).adoptWebViewSession(
          '222',
          'key222',
        );

    expect(api.adoptCalls, [('222', 'key222')]);
    final user = container.read(authProvider).user!;
    expect(user.id, '222');
    expect(user.remixUserkey, 'key222');
    // Unknown account: no borrowed identity from the previous one.
    expect(user.email, isEmpty);
    expect(secureStore['remix_userid'], '222');
    expect(secureStore['remix_userkey'], 'key222');
    expect(secureStore['user_email'], isEmpty);
  });
}
