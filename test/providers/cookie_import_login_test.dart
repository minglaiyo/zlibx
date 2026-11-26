import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';
import 'package:zlibx/services/cookie_import.dart';

/// [AuthNotifier.loginWithCookie] tests: a pasted browser session logs
/// in through the normal token flow and is persisted like any login
/// (encrypted store + saved-accounts list), never as a password.
///
/// Secure storage is mocked at the plugin's method channel and Hive
/// boxes are opened against a temp dir, following
/// `adopt_webview_session_test.dart`.
class _FakeApi implements ZLibraryApi {
  _FakeApi({this.failure});

  /// The failing answer `loginWithToken` should report, or null for success.
  ApiResponse<User>? failure;

  int loginWithTokenCalls = 0;
  bool sessionCleared = false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  void clearSession() {
    sessionCleared = true;
  }

  @override
  Future<ApiResponse<User>> loginWithToken(
    String userId,
    String userKey,
  ) async {
    loginWithTokenCalls++;
    if (failure != null) return failure!;
    return ApiResponse.ok(
      User(
        id: userId,
        email: 'cookie@example.com',
        name: 'Cookie User',
        remixUserkey: userKey,
      ),
    );
  }
}

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// In-memory store backing the mocked secure-storage channel.
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

Future<ProviderContainer> _container(_FakeApi api) async {
  final container = ProviderContainer(
    overrides: [zlibraryApiProvider.overrideWithValue(api)],
  );
  addTearDown(container.dispose);
  // Boot the real AuthNotifier signed out (empty mocked store) and
  // wait for _init to settle.
  container.read(authProvider.notifier);
  await container.read(authProvider.notifier).ready;
  return container;
}

void main() {
  setUpAll(() async {
    _mockSecureStorage();
    _hiveTempDir = await Directory.systemTemp.createTemp('cookie_import');
    Hive.init(_hiveTempDir!.path);
    await Hive.openBox('settings');
    await Hive.openBox('auth');
  });

  setUp(() {
    secureStore.clear();
    _mockSecureStorage();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  tearDownAll(() async {
    await Hive.close();
    await _hiveTempDir?.delete(recursive: true);
  });

  test('raw header logs in and persists the pair', () async {
    final api = _FakeApi();
    final container = await _container(api);

    final ok = await container
        .read(authProvider.notifier)
        .loginWithCookie('other=x; remix_userid=333; remix_userkey=key333');

    expect(ok, isTrue);
    expect(api.loginWithTokenCalls, 1);
    expect(api.sessionCleared, isTrue);
    final user = container.read(authProvider).user!;
    expect(user.id, '333');
    expect(user.remixUserkey, 'key333');
    expect(user.email, 'cookie@example.com');
    expect(secureStore['remix_userid'], '333');
    expect(secureStore['remix_userkey'], 'key333');
  });

  test('rejected pair fails without persisting anything', () async {
    final api = _FakeApi(
      failure: ApiResponse.fail('session expired', statusCode: 401),
    );
    final container = await _container(api);

    final ok = await container
        .read(authProvider.notifier)
        .loginWithCookie('remix_userid=333; remix_userkey=stale');

    expect(ok, isFalse);
    expect(api.loginWithTokenCalls, 1);
    expect(container.read(authProvider).user, isNull);
    expect(secureStore, isEmpty);
  });

  test('unparsable text throws before any session call', () async {
    final api = _FakeApi();
    final container = await _container(api);

    await expectLater(
      container.read(authProvider.notifier).loginWithCookie('hello'),
      throwsA(isA<CookieImportException>()),
    );
    expect(api.loginWithTokenCalls, 0);
  });
}
