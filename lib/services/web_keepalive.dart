import 'dart:async';

import 'package:flutter/services.dart';

import 'package:zlibx/utils/diagnostics.dart';

/// Bridge to the Android foreground service that keeps the LAN book
/// server reachable while the screen is off (see
/// `WebKeepaliveService.kt`). While the server runs, the service holds
/// a wake lock + Wi-Fi lock and pins a notification whose text is the
/// address other devices should open; its Stop button reports back
/// through [onAction].
///
/// All calls are best-effort: on a non-Android platform or when the
/// channel is unavailable, the server still runs in the app process —
/// this only affects screen-off keep-alive, not the server itself.
class WebKeepalive {
  WebKeepalive._();

  static const MethodChannel _channel = MethodChannel('zlibx/web_keepalive');
  static const MethodChannel _actionChannel = MethodChannel(
    'zlibx/web_keepalive_action',
  );

  /// Registered once: receives 'stop' from the notification's Stop
  /// button. Set by the bootstrap wiring.
  static void Function(String action)? onAction;

  static bool _registered = false;

  /// Register the action callback and tell the native side which
  /// channel to invoke for actions. Call once at startup.
  static void register() {
    if (_registered) return;
    _registered = true;
    _actionChannel.setMethodCallHandler((call) async {
      onAction?.call(call.method);
      return null;
    });
    unawaited(
      _channel
          .invokeMethod<void>('setActionChannel', {
            'name': _actionChannel.name,
          })
          .catchError((Object error) {
            logIgnored('web_keepalive_channel', error);
          }),
    );
  }

  /// Start (or refresh) the foreground service. [text] is shown in the
  /// notification, e.g. the address other devices should open.
  static Future<void> start({required String text}) async {
    try {
      await _channel.invokeMethod<void>('start', {'text': text});
    } on Object catch (error) {
      // Non-Android / channel unavailable: the server still runs, just
      // without screen-off keep-alive.
      logIgnored('web_keepalive_channel', error);
    }
  }

  /// The server stopped: drop the service, its locks and the notice.
  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on Object catch (error) {
      // Best-effort — but not silent (审查 v2 P2-2).
      logIgnored('web_keepalive_channel', error);
    }
  }

  /// Refresh the shown address (a hotspot address changes when the
  /// hotspot is re-enabled) and renew the locks.
  static Future<void> updateText(String text) async {
    try {
      await _channel.invokeMethod<void>('updateText', {'text': text});
    } on Object catch (error) {
      // Best-effort — but not silent (审查 v2 P2-2).
      logIgnored('web_keepalive_channel', error);
    }
  }

  /// Whether the OS already exempts zlibx from battery optimization.
  /// False on non-Android / channel unavailable.
  static Future<bool> isIgnoringBatteryOptimization() async {
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimization',
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on Object catch (error) {
      logIgnored('web_keepalive_channel', error);
      return false;
    }
  }

  /// Fire the system dialog that exempts zlibx from battery
  /// optimization in one tap. Best-effort: OEM builds without the
  /// dialog activity simply do nothing (the settings entry still says
  /// what to do by hand).
  static Future<void> requestIgnoreBatteryOptimization() async {
    try {
      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimization');
    } on Object catch (error) {
      // Best-effort — but not silent (审查 v2 P2-2).
      logIgnored('web_keepalive_channel', error);
    }
  }
}
