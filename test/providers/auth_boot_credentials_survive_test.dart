// What may be concluded about the stored session — at boot (`_init`) and
// from a mid-session refusal (`handleSessionRejected`).
//
// A failed `loginWithToken` at boot means one of two completely different
// things, and the old code told them apart only by a substring table:
//
//   * the line never gave us an answer we could read — Cloudflare /
//     DDoS-Guard wall, 5xx, 429, empty or non-JSON body, a payload without
//     a user object, a transport exception;
//   * the line looked at our `remix_userid` / `remix_userkey` pair and said
//     no.
//
// Only the second may drop credentials: `clearAccount(userId)` drops only
// that account's pair and its saved entry (the old `clearCredentials()`
// also deleted the whole saved-accounts list, so a wrong verdict turned a
// network bad day into "retype your password" for every account — the
// reported 重进 App 掉登录). Those cases are the answers a mirror really
// gives on a bad day; the pair stays on disk and the session is kept as
// cached.
//
// The other half is the second reported symptom (401 不续期): a refusal seen
// while running changed nothing until the next cold boot. Both live in one
// file because they are one verdict on one pair, reached through the same
// fake API and mocked secure store.
//
// The secure-store mock / temp Hive boxes follow
// `adopt_webview_session_test.dart`; the fake API implements only what
// these paths call.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/auth_provider.dart';
import 'package:zlibx/providers/zlibrary_provider.dart';

class _FakeApi implements ZLibraryApi {
  _FakeApi({this.failure, this.throws});

  /// The failing answer `loginWithToken` should report, or null for success.
  /// Mutable: the mid-session tests boot into a good session and then flip
  /// the line's answer.
  ApiResponse<User>? failure;

  /// When set, `loginWithToken` throws this instead of answering.
  Object? throws;

  int loginWithTokenCalls = 0;
  bool sessionCleared = false;

  /// How often the auth layer asked which line it is on. A rejection must
  /// answer that, because the WebView cookie jar holds the same pair for
  /// that host and is the one store the logout cannot reach except by name
  /// (`_dropWebViewSession`). There is no CookieManager on a test host, so
  /// this is as far as the call can be observed here.
  int domainReads = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');

  @override
  String get domain {
    domainReads++;
    return 'bookroom.lifestyle';
  }

  @override
  void clearSession() {
    sessionCleared = true;
  }

  @override
  Future<ApiResponse<User>> loginWithToken(String userId, String userKey) async {
    loginWithTokenCalls++;
    final thrown = throws;
    if (thrown != null) throw thrown;
    final failure = this.failure;
    if (failure != null) return failure;
    return ApiResponse.ok(User(
      id: userId,
      email: 'alice@example.com',
      name: 'Alice',
      remixUserkey: userKey,
    ));
  }
}

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

final Map<String, String> secureStore = <String, String>{};

/// Keys the secure-store mock should fail on (`PlatformException` the way
/// flutter_secure_storage does when the Keystore refuses).
Set<String> failingReads = <String>{};

void _mockSecureStorage() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    switch (call.method) {
      case 'read':
        final key = call.arguments['key'] as String;
        if (failingReads.contains(key)) {
          throw PlatformException(code: 'GENERIC_ERROR', message: 'keystore');
        }
        return secureStore[key];
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

/// Boot the real [AuthNotifier] against [api] and settle `_init`.
///
/// [seed] writes the stored session into the mocked secure store first;
/// `seed: false` boots the way a fresh install does (nothing stored).
///
/// `state` is the settled boot state; `read()` gives the current one, which
/// is what the mid-session tests need after they drive the notifier.
Future<
    ({
      AuthState state,
      AuthState Function() read,
      AuthNotifier notifier,
    })> _boot(
  _FakeApi api, {
  bool seed = true,
}) async {
  final container = ProviderContainer(
    overrides: [zlibraryApiProvider.overrideWithValue(api)],
  );
  addTearDown(container.dispose);
  if (seed) {
    secureStore['remix_userid'] = '111';
    secureStore['remix_userkey'] = 'oldKey';
    secureStore['user_email'] = 'alice@example.com';
    secureStore['user_name'] = 'Alice';
  }
  final notifier = container.read(authProvider.notifier);
  await notifier.ready;
  return (
    state: container.read(authProvider),
    read: () => container.read(authProvider),
    notifier: notifier,
  );
}

void main() {
  setUpAll(() async {
    _mockSecureStorage();
    _hiveTempDir = await Directory.systemTemp.createTemp('auth_boot');
    Hive.init(_hiveTempDir!.path);
    await Hive.openBox('settings');
    await Hive.openBox('auth');
  });

  setUp(() {
    secureStore.clear();
    failingReads = <String>{};
    _mockSecureStorage();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  tearDownAll(() async {
    // Hive holds handles; on Windows the box must close before the dir goes.
    await Hive.close();
    await _hiveTempDir?.delete(recursive: true);
  });

  group('boot keeps the session when the line gave no verdict', () {
    // Every one of these is an answer the plugin really produces (see
    // `_fromError` / `_fromResponse` in zlibrary_api.dart) and none of them
    // says anything about the stored pair.
    final unreachable = <String, ApiResponse<User>>{
      'HTTP 503': ApiResponse.fail('HTTP 503', statusCode: 503),
      'HTTP 429 rate limit':
          ApiResponse.fail('non-JSON response (HTTP 429)', statusCode: 429),
      'browser check page': ApiResponse.fail(
        'HTTP 403: browser check page',
        statusCode: 403,
      ),
      'empty body': ApiResponse.fail('empty response (HTTP 500)',
          statusCode: 500),
      'success:0 without a message':
          ApiResponse.fail('profile failed', statusCode: 200),
      'profile without user object':
          ApiResponse.fail('profile response had no user', statusCode: 200),
      'Cloudflare block': ApiResponse.fail('cf_blocked', statusCode: 403),
      'redirect chain did not settle':
          ApiResponse.fail('too many redirects', statusCode: 302),
    };

    for (final entry in unreachable.entries) {
      test(entry.key, () async {
        final api = _FakeApi(failure: entry.value);
        final result = await _boot(api);

        // The gate in front of the call really was open (built-in line), so
        // this exercises the classification and not the early return.
        expect(api.loginWithTokenCalls, 1);
        expect(result.state.user?.id, '111', reason: 'still logged in');
        expect(result.state.user?.remixUserkey, 'oldKey');
        expect(result.state.lineUnavailable, isTrue);
        expect(secureStore['remix_userkey'], 'oldKey',
            reason: 'credentials must survive on disk');
        expect(secureStore['remix_userid'], '111');
      });
    }

    test('transport exception', () async {
      final api = _FakeApi(throws: Exception('SocketException: host lookup'));
      final result = await _boot(api);

      expect(api.loginWithTokenCalls, 1);
      expect(result.state.user?.remixUserkey, 'oldKey');
      expect(result.state.lineUnavailable, isTrue);
      expect(secureStore['remix_userkey'], 'oldKey');
    });
  });

  group('secure storage', () {
    test('a read that fails once and succeeds on retry still logs in',
        () async {
      // Keystore blips are real (GenericIOException / BadPaddingException on
      // some devices). One failed read must not be reported as "no session".
      var readAttempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        switch (call.method) {
          case 'read':
            final key = call.arguments['key'] as String;
            if (key == 'remix_userkey') {
              readAttempts++;
              if (readAttempts == 1) {
                throw PlatformException(code: 'GENERIC_ERROR');
              }
            }
            return secureStore[key];
          case 'write':
            secureStore[call.arguments['key'] as String] =
                call.arguments['value'] as String;
            return null;
          case 'delete':
            secureStore.remove(call.arguments['key'] as String);
            return null;
          default:
            return null;
        }
      });
      final api = _FakeApi();
      final result = await _boot(api);

      expect(readAttempts, greaterThan(1), reason: 'the read was retried');
      expect(api.loginWithTokenCalls, 1, reason: 'the pair was still used');
      expect(result.state.user?.id, '111');
      expect(result.state.lineUnavailable, isFalse);
    });

    test('a storage that keeps refusing is not treated as logged out',
        () async {
      failingReads = {'remix_userkey'};
      final api = _FakeApi();
      final result = await _boot(api);

      expect(api.loginWithTokenCalls, 0, reason: 'no pair to send');
      expect(secureStore['remix_userkey'], 'oldKey',
          reason: 'nothing may be deleted over a read failure');
      expect(result.state.user, isNull);
      // The state must say the local session could not be read, which is not
      // the same thing as "never signed in": the UI offers a retry instead.
      expect(result.state.storageUnavailable, isTrue);
    });
  });

  // The other half of the narrowed verdict: it must not have become "never
  // clear". A pair the line refused stays on disk forever, every request
  // fails, and the login screen never appears.
  group('boot logs out on a real rejection', () {
    final rejected = <String, ApiResponse<User>>{
      'HTTP 401': ApiResponse.fail(
        'Invalid userkey',
        statusCode: 401,
        authRejected: true,
      ),
      'success:0 blaming the session': ApiResponse.fail(
        'Token is expired',
        statusCode: 200,
        authRejected: true,
      ),
    };

    for (final entry in rejected.entries) {
      test(entry.key, () async {
        final api = _FakeApi(failure: entry.value);
        final result = await _boot(api);

        expect(api.loginWithTokenCalls, 1);
        expect(result.state.user, isNull, reason: 'the pair is dead');
        expect(api.sessionCleared, isTrue,
            reason: 'the plugin must stop sending the refused pair');
        expect(secureStore.containsKey('remix_userkey'), isFalse);
        expect(secureStore.containsKey('remix_userid'), isFalse);
        expect(api.domainReads, greaterThan(0),
            reason: 'the refused pair must go out of the WebView jar too');
      });
    }
  });

  // Module 2 ③: a refusal seen while the app is running used to change
  // nothing until the next cold boot. The plugin reports it and the auth
  // layer re-verifies once.
  group('a mid-session rejection re-verifies the pair', () {
    test('the line refusing the pair again ends the session', () async {
      final api = _FakeApi();
      final result = await _boot(api);
      expect(result.state.isAuthenticated, isTrue);

      // The plugin's 401 on some other endpoint is what calls this.
      api.failure = ApiResponse.fail(
        'Invalid userkey',
        statusCode: 401,
        authRejected: true,
      );
      await result.notifier.handleSessionRejected();

      final state = result.read();
      expect(api.loginWithTokenCalls, 2, reason: 'boot + one re-verification');
      expect(api.sessionCleared, isTrue);
      expect(state.user, isNull);
      expect(state.error, 'Invalid userkey');
      expect(secureStore.containsKey('remix_userkey'), isFalse,
          reason: 'a refused pair must not survive to the next boot');
      expect(api.domainReads, greaterThan(0),
          reason: 'and it must not stay installed in the WebView jar');
    });

    test('a pair the profile still accepts is left alone', () async {
      // A proxy or an endpoint that 401s for its own reasons must not cost
      // the user their session: the re-check answers OK and nothing changes.
      final api = _FakeApi();
      final result = await _boot(api);
      expect(result.state.isAuthenticated, isTrue);

      await result.notifier.handleSessionRejected();

      final state = result.read();
      expect(api.loginWithTokenCalls, 2);
      expect(api.sessionCleared, isFalse);
      expect(state.isAuthenticated, isTrue);
      expect(state.lineUnavailable, isFalse);
      expect(secureStore['remix_userkey'], 'oldKey');
    });

    test('no verdict from the line keeps the session and flags the line',
        () async {
      final api = _FakeApi();
      final result = await _boot(api);

      api.failure = ApiResponse.fail('cf_blocked', statusCode: 403);
      await result.notifier.handleSessionRejected();

      final state = result.read();
      expect(api.sessionCleared, isFalse);
      expect(state.user?.remixUserkey, 'oldKey');
      expect(state.lineUnavailable, isTrue);
      expect(secureStore['remix_userkey'], 'oldKey');
    });

    test('a burst of rejections costs one re-verification', () async {
      // A screen that fires a dozen requests behind a wall would otherwise
      // start a dozen profile calls — and the re-check's own 401 would
      // re-enter it.
      final api = _FakeApi();
      final result = await _boot(api);
      expect(result.state.isAuthenticated, isTrue);
      api.failure = ApiResponse.fail(
        'Invalid userkey',
        statusCode: 401,
        authRejected: true,
      );
      api.loginWithTokenCalls = 0; // count only the re-check

      await Future.wait([
        for (var i = 0; i < 5; i++) result.notifier.handleSessionRejected(),
      ]);

      expect(api.loginWithTokenCalls, 1, reason: 'one re-verification');
      expect(result.read().user, isNull);
    });

    test('the re-verification cannot re-enter itself', () async {
      // The re-check calls the same endpoint that refused, so its own 401
      // reports a rejection again — that must not start a second check.
      final api = _FakeApi();
      final result = await _boot(api);
      api.failure = ApiResponse.fail(
        'Invalid userkey',
        statusCode: 401,
        authRejected: true,
      );
      api.loginWithTokenCalls = 0;

      await result.notifier.handleSessionRejected();

      expect(api.loginWithTokenCalls, 1, reason: 'the check asked once');
    });

    test('nothing is re-verified while the app is signed out', () async {
      final api = _FakeApi();
      final result = await _boot(api, seed: false);
      expect(result.state.isAuthenticated, isFalse);

      await result.notifier.handleSessionRejected();

      expect(api.loginWithTokenCalls, 0, reason: 'no pair to check');
      expect(api.sessionCleared, isFalse);
    });

    test('the real client is built with the notice wired', () {
      // The tests above call handleSessionRejected directly; production
      // reaches it only through the hook the API instance carries. A
      // refactor of zlibraryApiProvider that drops the assignment would
      // otherwise leave every case here green and the fix dead.
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(zlibraryApiProvider).onSessionRejected, isNotNull);
    });
  });
}
