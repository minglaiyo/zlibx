// WebKeepalive: channel payloads, best-effort error swallowing, and
// the battery-optimization helpers behind the settings entry.
//
// The bridge must never throw into the caller's face — the server and
// the settings page work with or without the keep-alive — so the tests
// prove failures come back as values, plus that every call carries the
// exact payload the native handler switches on.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/web_keepalive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('zlibx/web_keepalive');
  const actionChannel = MethodChannel('zlibx/web_keepalive_action');

  final log = <MethodCall>[];
  var ignoreAnswer = false;
  var failAll = false;

  setUp(() {
    log.clear();
    ignoreAnswer = false;
    failAll = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (failAll) throw PlatformException(code: 'boom');
      log.add(call);
      if (call.method == 'isIgnoringBatteryOptimization') return ignoreAnswer;
      return null;
    });
  });

  tearDown(() {
    WebKeepalive.onAction = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('start / updateText / stop carry the address text', () async {
    await WebKeepalive.start(text: 'http://192.168.1.5:8080/');
    await WebKeepalive.updateText('http://192.168.1.9:8080/');
    await WebKeepalive.stop();
    expect(log.map((c) => c.method), ['start', 'updateText', 'stop']);
    expect(log[0].arguments, {'text': 'http://192.168.1.5:8080/'});
    expect(log[1].arguments, {'text': 'http://192.168.1.9:8080/'});
    expect(log[2].arguments, isNull);
  });

  test('battery helpers parse the native answer', () async {
    ignoreAnswer = true;
    expect(await WebKeepalive.isIgnoringBatteryOptimization(), isTrue);
    ignoreAnswer = false;
    expect(await WebKeepalive.isIgnoringBatteryOptimization(), isFalse);
  });

  test('requestIgnoreBatteryOptimization fires the dialog method', () async {
    await WebKeepalive.requestIgnoreBatteryOptimization();
    expect(log.single.method, 'requestIgnoreBatteryOptimization');
  });

  test('a failing channel is swallowed, not thrown to the caller',
      () async {
    failAll = true;
    await WebKeepalive.start(text: 'http://x/');
    await WebKeepalive.updateText('http://x/');
    await WebKeepalive.stop();
    await WebKeepalive.requestIgnoreBatteryOptimization();
    expect(await WebKeepalive.isIgnoringBatteryOptimization(), isFalse);
    // Nothing reached the (failing) channel.
    expect(log, isEmpty);
  });

  test('a channelless platform answers false, not a crash', () async {
    // No mock registered: the host binding answers with
    // MissingPluginException, exactly like a non-Android platform.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    expect(await WebKeepalive.isIgnoringBatteryOptimization(), isFalse);
  });

  test('register wires the action channel and the Stop button', () async {
    final actions = <String>[];
    WebKeepalive.register();
    WebKeepalive.onAction = actions.add;

    // register() told the native side where to send actions.
    expect(log.first.method, 'setActionChannel');
    expect(
      (log.first.arguments as Map)['name'],
      'zlibx/web_keepalive_action',
    );

    // The native notification button pushes the action INTO Dart as a
    // platform message. (invokeMethod from the test would be swallowed
    // by this file's outgoing mock — the push has to come from the
    // platform side, like the real button.)
    Future<void> pushFromNative(String method) {
      return TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        actionChannel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (ByteData? reply) {},
      );
    }

    await pushFromNative('stop');
    await pushFromNative('unknown');
    expect(actions, ['stop', 'unknown']);
  });
}
