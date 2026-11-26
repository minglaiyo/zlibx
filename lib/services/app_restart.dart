import 'package:flutter/services.dart';

/// Restarts the whole app process (native side schedules a relaunch
/// of the launcher activity, then kills this process).
class AppRestart {
  static const _channel = MethodChannel('zlibx/app_restart');

  /// Returns true when the native side accepted the restart request.
  /// False on non-Android or on a channel error (app keeps running).
  static Future<bool> restart() async {
    try {
      await _channel.invokeMethod<void>('restart');
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
