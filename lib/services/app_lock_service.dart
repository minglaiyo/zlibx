// Privacy lock (隐私锁): biometric / device-credential gate on app resume,
// plus the FLAG_SECURE recents-blur companion. Android-native via
// local_auth (BiometricPrompt) and the `zlibx/media_store` channel's
// setSecureFlag (see MainActivity — FlutterFragmentActivity is a
// local_auth requirement).
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:meta/meta.dart';

import 'hive_service.dart';
import '../utils/diagnostics.dart';

/// settingsBox 里记录"最后一次离开前台的时刻"（毫秒）的键。
///
/// 为什么必须落盘：Android 随时会杀掉后台进程，用户"切后台再回来"很大
/// 概率变成一次冷启动，而不是 resumed 生命周期回调。锁的判定如果只挂在
/// 生命周期上，上滑杀掉再打开就直接绕过了。
const String appLockLeftForegroundKey = 'appLockLeftForegroundAt';

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

/// 判定冷启动是否需要解锁。纯函数，同上。
///
/// 冷启动意味着进程刚刚起来：上一次要么被系统杀掉、要么被用户划掉，
/// 总之"离开前台"这件事已经无法用内存状态证明了。
///
/// - [enabled] 关闭时永不锁。
/// - [leftForegroundAtMs] 为 null（没有记录：前台被杀、或升级前的旧
///   数据）→ 锁。安全默认：说不清什么时候离开的，就当需要重新验证。
/// - 否则按上次离开前台的时长对照 [timeoutSeconds] 判定，语义与
///   [shouldLockOnResume] 一致（"1 分钟后"档位在窗口内返回不锁）。
bool shouldLockOnColdStart({
  required bool enabled,
  required int timeoutSeconds,
  required int? leftForegroundAtMs,
  required DateTime now,
}) {
  if (!enabled) return false;
  if (leftForegroundAtMs == null) return true;
  final elapsed = now.difference(
    DateTime.fromMillisecondsSinceEpoch(leftForegroundAtMs),
  );
  // 时钟回拨 / 未来时间戳：elapsed 为负，按"说不清"处理，锁。
  if (elapsed.isNegative) return true;
  return elapsed.inSeconds >= timeoutSeconds;
}

/// 一次系统验证的结果分类。UI 层按类别给不同反馈：普通失败可以马上
/// 重试，锁定要等，凭据消失则锁永远不可能再被满足——那种情况下必须
/// 给用户一条出路，否则就是把人永久关在自己门外。
enum AppLockAuthResult {
  /// 验证通过。
  success,

  /// 用户取消、指纹没认出来：立刻可以重试。
  retry,

  /// 失败次数过多，系统临时/永久锁定了生物识别。
  lockedOut,

  /// 设备上已经没有可用的指纹 / 面部 / 锁屏密码。
  unavailable,

  /// 其它异常（native 侧卡住、activity 不可用等）。
  error,
}

/// 锁定状态的单一事实来源。全局单例：锁是 app 级行为，不属于任何
/// 页面；覆盖层（AppLockOverlay）监听 [locked]，生命周期钩子在
/// main.dart 里调 [handlePaused] / [handleResumed]，冷启动在 main.dart
/// 里调 [restoreOnStartup]。
class AppLockController {
  AppLockController._();

  static final AppLockController instance = AppLockController._();

  final ValueNotifier<bool> locked = ValueNotifier<bool>(false);
  DateTime? _backgroundedAt;
  LocalAuthentication _auth = LocalAuthentication();

  /// 测试接缝：注入假的 [LocalAuthentication]，让锁门能测"验证成功 /
  /// 失败 / 凭据消失"三条分支。不加这个的话 flutter_test 里
  /// authenticate() 的 Future 永远不会回包（插件不存在），整条 UI 路径
  /// 都测不了。生产代码不调用。
  @visibleForTesting
  set authClientForTest(LocalAuthentication value) => _auth = value;

  /// 冷启动时按持久化状态决定开局是否就是锁着的（见
  /// [appLockLeftForegroundKey]）。必须在 runApp 之前调用，否则第一帧
  /// 会把内容闪出来一下再盖住——那正是隐私锁要避免的画面。
  void restoreOnStartup({
    required bool enabled,
    required int timeoutSeconds,
    required int? leftForegroundAtMs,
  }) {
    _backgroundedAt = leftForegroundAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(leftForegroundAtMs);
    if (shouldLockOnColdStart(
      enabled: enabled,
      timeoutSeconds: timeoutSeconds,
      leftForegroundAtMs: leftForegroundAtMs,
      now: DateTime.now(),
    )) {
      locked.value = true;
    }
  }

  /// paused：记下离开前台的时间并落盘；"立即锁定"模式此刻就锁。
  /// 已锁状态下再离开不变（解锁只由认证成功触发）。
  void handlePaused({required bool enabled, required int timeoutSeconds}) {
    _backgroundedAt = DateTime.now();
    _persistLeftForeground(_backgroundedAt!);
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
  ///
  /// 同时清掉落盘的离开前台时间：这条记录只对"这一次离开"有意义，
  /// 留在盘上会让下一次冷启动拿一个早已过期的时间去比对。
  void unlock() {
    _backgroundedAt = null;
    _clearLeftForeground();
    locked.value = false;
  }

  /// 设备上是否有可用的生物识别 / 设备凭据。开关打开前先探测：
  /// 什么都没有时打开开关只会把自己锁在门外。
  ///
  /// 两个探测的语义（见 local_auth_android 的 LocalAuthPlugin）：
  /// `canCheckBiometrics` 只看有没有录入生物识别，`isDeviceSupported`
  /// 是 `keyguardManager.isDeviceSecure() || 有生物识别`——只有 PIN 的
  /// 机器靠后者才算支持，所以两个都要问。
  Future<bool> canAuthenticate() async {
    try {
      return await _auth.canCheckBiometrics ||
          await _auth.isDeviceSupported();
    } catch (error) {
      logIgnored('app_lock', error);
      return false;
    }
  }

  /// 弹系统 BiometricPrompt（指纹 / 面部 / 设备密码）。
  ///
  /// 三个非显然的选项选择，都是为了解决"按钮按了没反应"：
  /// - stickyAuth=false：true 时 local_auth 在"弹窗期间 activity 被
  ///   暂停"的路径上（AuthenticationHelper.onAuthenticationError 的
  ///   ERROR_CANCELED 分支）直接 return，既不回调 Dart 也不注销监听，
  ///   Dart 侧的 Future 永远挂着——覆盖层的按钮就永久禁用了。锁门是
  ///   "一次一次问"的场景，不需要跨生命周期保持会话。
  /// - useErrorDialogs=false：插件自带的"去设置"弹窗会把 app 推到后台，
  ///   和锁门流程互相打断；错误文案由覆盖层自己显示更可控。
  /// - 先 cancelPendingAuth()：native 侧的 authInProgress 只有靠
  ///   onAuthenticationCompleted / stopAuthentication 才会清，一旦残留，
  ///   之后每次 authenticate 都直接返回 auth_in_progress，永远弹不出
  ///   系统提示。每次尝试前取消一次，保证状态是干净的。
  Future<AppLockAuthResult> authenticate(String localizedReason) async {
    await cancelPendingAuth();
    try {
      final ok = await _auth.authenticate(
        localizedReason: localizedReason,
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: false,
          useErrorDialogs: false,
        ),
      );
      return ok ? AppLockAuthResult.success : AppLockAuthResult.retry;
    } on PlatformException catch (error) {
      // 用户取消 / 多次失败锁定 / 无 enrolled 凭据等都会走这里。
      logIgnored('app_lock', error);
      return switch (error.code) {
        'NotAvailable' => AppLockAuthResult.unavailable,
        'NotEnrolled' => AppLockAuthResult.unavailable,
        'LockedOut' => AppLockAuthResult.lockedOut,
        'PermanentlyLockedOut' => AppLockAuthResult.lockedOut,
        // auth_in_progress / no_activity / no_fragment_activity 和
        // 其它未知码：不是"用户没验过"，重试可能仍然失败，但也不该
        // 谎称凭据不存在——按可重试处理，同时留一条日志。
        _ => AppLockAuthResult.retry,
      };
    } catch (error) {
      logIgnored('app_lock', error);
      return AppLockAuthResult.error;
    }
  }

  /// 取消 native 侧可能残留的验证会话。失败不抛：没有会话时
  /// stopAuthentication 本身就是 no-op。
  Future<void> cancelPendingAuth() async {
    try {
      await _auth.stopAuthentication();
    } catch (error) {
      logIgnored('app_lock', error);
    }
  }

  /// 落盘 / 清盘都吞异常：这两个函数跑在 didChangeAppLifecycleState 的
  /// 调用栈上，抛出去会把所有生命周期监听一起打断（包括下载前台服务的
  /// 那些）。写失败最多退化成"这次冷启动不锁"，不能拖累全局。
  void _persistLeftForeground(DateTime at) {
    try {
      unawaited(
        HiveService.settingsBox
            .put(appLockLeftForegroundKey, at.millisecondsSinceEpoch)
            .catchError((Object error) {
          logIgnored('app_lock', error);
        }),
      );
    } catch (error) {
      logIgnored('app_lock', error);
    }
  }

  void _clearLeftForeground() {
    try {
      unawaited(
        HiveService.settingsBox
            .delete(appLockLeftForegroundKey)
            .catchError((Object error) {
          logIgnored('app_lock', error);
        }),
      );
    } catch (error) {
      logIgnored('app_lock', error);
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
