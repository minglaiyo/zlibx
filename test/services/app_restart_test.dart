// Unit tests for AppRestart.
//
// The 'zlibx/app_restart' channel is stubbed with an in-memory fake:
// restart returns true when the native side accepts it, false when
// the fake throws a PlatformException, and false when no handler is
// registered (MissingPluginException — the process normally dies
// ~100 ms after a successful call, so the true path only matters
// for the channel contract, not for observing a restart).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zlibx/services/app_restart.dart';

void main() {
  const channel = MethodChannel('zlibx/app_restart');

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('restart returns true when the native side accepts it', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'restart');
      return null;
    });
    expect(await AppRestart.restart(), isTrue);
  });

  test('restart returns false when the channel throws PlatformException',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      throw PlatformException(code: 'restart_failed');
    });
    expect(await AppRestart.restart(), isFalse);
  });

  test('restart returns false with no handler registered', () async {
    // No mock handler: the invoke throws MissingPluginException.
    expect(await AppRestart.restart(), isFalse);
  });
}
