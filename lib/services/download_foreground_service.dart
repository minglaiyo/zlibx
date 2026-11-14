import 'dart:async';

import 'package:flutter/services.dart';

/// O1: bridge to the Android foreground service that keeps downloads
/// alive in the background (see `DownloadForegroundService.kt`). The
/// service shows a progress notification and reports pause/cancel actions
/// fired from its notification buttons back through [onAction].
///
/// All calls are best-effort: on a non-Android platform or when the
/// channel is unavailable, the download still runs in the app process —
/// this only affects background keep-alive, not the download itself.
class DownloadForegroundService {
  DownloadForegroundService._();

  static const MethodChannel _channel =
      MethodChannel('zlibx/download_service');
  static const MethodChannel _actionChannel =
      MethodChannel('zlibx/download_service_action');

  /// Registered once: receives 'pause' / 'cancel' from the notification
  /// action buttons. Set by the download engine.
  static void Function(String action)? onAction;

  static bool _registered = false;

  /// Register the action callback and tell the native side which channel
  /// to invoke for actions. Call once at startup.
  static void register() {
    if (_registered) return;
    _registered = true;
    _actionChannel.setMethodCallHandler((call) async {
      onAction?.call(call.method);
      return null;
    });
    unawaited(
      _channel.invokeMethod<void>('setActionChannel', _actionChannel.name),
    );
  }

  /// Request POST_NOTIFICATIONS (Android 13+) so the download progress
  /// notification is visible. Best-effort.
  static Future<void> requestNotificationPermission() async {
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
    } on Object catch (_) {
      // The service runs without the grant; the notification is only
      // suppressed.
    }
  }

  /// Start (or keep) the foreground service for a new download.
  static Future<void> start() async {
    try {
      await _channel.invokeMethod<void>('start');
    } on Object catch (_) {
      // Non-Android / channel unavailable: no background keep-alive.
    }
  }

  /// A download finished: drop the count, stop when it reaches 0.
  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on Object catch (_) {
      // Best-effort.
    }
  }

  /// Push progress text to the notification.
  static Future<void> updateProgress(String text) async {
    try {
      await _channel.invokeMethod<void>('updateProgress', {'text': text});
    } on Object catch (_) {
      // Best-effort.
    }
  }
}
