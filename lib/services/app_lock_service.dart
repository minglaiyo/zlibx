// Privacy lock (隐私锁): biometric / device-credential gate on app resume,
// plus the FLAG_SECURE recents-blur companion. Android-native via
// local_auth (BiometricPrompt) and the `zlibx/media_store` channel's
// setSecureFlag (see MainActivity — FlutterFragmentActivity is a
// local_auth requirement).
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../utils/diagnostics.dart';

/// 判定切后台回来时是否需要解锁。纯函数：单元测试直接测它，不碰
/// local_auth / Hive。
///
/// [enabled] 关闭时永不锁；[backgroundedAt] 为 null（还没离开过前台）
/// 永不锁；[timeoutSeconds] 为 0 表示切后台立即锁，否则超过该秒数才锁。
bool shouldLockOnResume({
  required bool enabled,
  required int timeoutSeconds,
  required DateTime? backgroundedAt,
  required DateTime now,
}) {
  if (!enabled) return false;
  if (backgroundedAt == null) return false;
  final elapsed = now.difference(backgroundedAt);
  return elapsed.inSeconds >= timeoutSeconds;
}

/// 锁定状态的单一事实来源。全局单例：锁是 app 级行为，不属于任何
/// 页面；覆盖层（AppLockOverlay）监听 [locked]，生命周期钩子在
/// main.dart 里调 [handleLifecycle]。
class AppLockController {
  AppLockController._();

  static final AppLockController instance = AppLockController._();

  final ValueNotifier<bool> locked = ValueNotifier<bool>(false);
  DateTime? _backgroundedAt;
  final LocalAuthentication _auth = LocalAuthentication();

  /// paused：记下离开前台的时间；"立即锁定"模式此刻就锁。
  /// 已锁状态下再离开不变（解锁只由认证成功触发）。
  void handlePaused({required bool enabled, required int timeoutSeconds}) {
    _backgroundedAt = DateTime.now();
    if (enabled && timeoutSeconds == 0 && !locked.value) {
      locked.value = true;
    }
  }

  /// resumed：延迟锁模式在这里判定是否到时。
  void handleResumed({required bool enabled, required int timeoutSeconds}) {
    final needs = shouldLockOnResume(
      enabled: enabled,
      timeoutSeconds: timeoutSeconds,
      backgroundedAt: _backgroundedAt,
      now: DateTime.now(),
    );
    if (needs && !locked.value) locked.value = true;
    _backgroundedAt = null;
  }

  /// 解锁成功。只有这一条路能把锁清掉。
  void unlock() {
    _backgroundedAt = null;
    locked.value = false;
  }

  /// 设备上是否有可用的生物识别 / 设备凭据。开关打开前先探测：
  /// 什么都没有时打开开关只会把自己锁在门外。
  Future<bool> canAuthenticate() async {
    try {
      return await _auth.canCheckBiometrics ||
          await _auth.isDeviceSupported();
    } catch (error) {
      logIgnored('app_lock', error);
      return false;
    }
  }

  /// 弹系统 BiometricPrompt（指纹 / 面部 / 设备密码）。返回是否解锁
  /// 成功。UI 层的对话框文案由系统提供，失败交给覆盖层提示重试。
  Future<bool> authenticate(String localizedReason) async {
    try {
      return await _auth.authenticate(
        localizedReason: localizedReason,
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } on PlatformException catch (error) {
      // 用户取消 / 多次失败锁定 / 无 enrolled 凭据等都会走这里。
      logIgnored('app_lock', error);
      return false;
    }
  }

  /// FLAG_SECURE：最近任务模糊 + 阻止截屏。走 MainActivity 的
  /// setSecureFlag（主线程改窗口旗标）；通道失败不抛——隐私增强
  /// 项，坏了不能挡住 app 其它功能。
  static Future<void> applySecureFlag(bool enabled) async {
    try {
      const channel = MethodChannel('zlibx/media_store');
      await channel.invokeMethod<bool>('setSecureFlag', {'enabled': enabled});
    } on PlatformException catch (error) {
      logIgnored('app_lock', error);
    }
  }
}
