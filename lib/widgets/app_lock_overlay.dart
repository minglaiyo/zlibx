import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/generated/app_localizations.dart';
import '../providers/settings_provider.dart';
import '../services/app_lock_service.dart';
import '../utils/app_snack.dart';

/// 隐私锁覆盖层：锁上时盖住整个 app（吸收所有点击），解锁按钮触发
/// 系统 BiometricPrompt。挂在 MaterialApp.builder 的 Stack 顶上
/// （见 main.dart），监听 AppLockController.locked。
class AppLockOverlay extends StatelessWidget {
  final Widget? child;

  const AppLockOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (child != null) child!,
        ValueListenableBuilder<bool>(
          valueListenable: AppLockController.instance.locked,
          builder: (context, locked, _) {
            if (!locked) return const SizedBox.shrink();
            return const _LockGate();
          },
        ),
      ],
    );
  }
}

/// 锁门本体。
///
/// 为什么是 StatefulWidget + 自带文案，而不是"按钮 + SnackBar"：
/// SnackBar 画在路由的 Scaffold 里，而这道门是 Positioned.fill 的
/// 不透明 ColoredBox，把它盖得严严实实——以前解锁失败的提示用户根本
/// 看不见，只会觉得按钮没反应。失败原因现在直接渲染在门里。
class _LockGate extends ConsumerStatefulWidget {
  const _LockGate();

  @override
  ConsumerState<_LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<_LockGate>
    with WidgetsBindingObserver {
  bool _authenticating = false;

  /// 上一次尝试的结果；null = 还没试过（或刚清掉）。
  ///
  /// 结果文案直接渲染在门里（见 _messageFor）。认证系统不可用时给的不再是
  /// "解锁失败，请重试"，而是"设备上没有可用的验证方式"，并且多一个
  /// "解锁并关闭隐私锁"的出口。
  AppLockAuthResult? _lastResult;

  /// 进门后自动弹一次系统验证（用户预期：切回来就看到指纹框，不用先
  /// 点一下）。只弹一次，失败后交回手动按钮；[didChangeAppLifecycleState]
  /// 在 resumed 时补上首帧没赶上的那一次。
  bool _autoAttempted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeAutoAuthenticate();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // 系统弹窗期间被切走：先把本地"正在验证"标记清掉，按钮绝不会停在
    // 禁用态（native 侧残留的会话由 authenticate() 开头的
    // cancelPendingAuth 收拾）。顺带补上没赶上的自动弹窗。
    if (_authenticating) setState(() => _authenticating = false);
    _maybeAutoAuthenticate();
  }

  void _maybeAutoAuthenticate() {
    if (_autoAttempted || _authenticating) return;
    // activity 还没 resumed 时弹 BiometricPrompt 会被系统立刻取消，
    // 白挨一次失败提示；等 resumed 再说。
    if (WidgetsBinding.instance.lifecycleState !=
        AppLifecycleState.resumed) {
      return;
    }
    _autoAttempted = true;
    _unlock();
  }

  Future<void> _unlock() async {
    if (_authenticating) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _authenticating = true);
    final AppLockAuthResult result;
    try {
      result = await AppLockController.instance
          .authenticate(l10n.appLockAuthReason);
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
    if (!mounted) return;
    if (result == AppLockAuthResult.success) {
      AppLockController.instance.unlock();
      return;
    }
    setState(() => _lastResult = result);
  }

  /// 出路：设备上的指纹 / 面部 / 锁屏密码已经不在了（被删、被重置、
  /// keystore 清空）。这时锁在技术上永远解不开，继续挡着只是把用户
  /// 关在自己门外。所以直接放行，并把隐私锁开关关掉、告知原因。
  Future<void> _disableLockAndUnlock() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(appLockEnabledProvider.notifier).setEnabled(false);
    if (!mounted) return;
    AppLockController.instance.unlock();
    showAppSnackOn(messenger, l10n.appLockTurnedOff);
  }

  String? _messageFor(AppLocalizations l10n, AppLockAuthResult result) {
    return switch (result) {
      AppLockAuthResult.success => null,
      AppLockAuthResult.retry => l10n.unlockFailed,
      AppLockAuthResult.error => l10n.unlockFailed,
      AppLockAuthResult.lockedOut => l10n.appLockLockedOut,
      AppLockAuthResult.unavailable => l10n.appLockAuthUnavailable,
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final message = _lastResult == null
        ? null
        : _messageFor(l10n, _lastResult!);
    final credentialGone = _lastResult == AppLockAuthResult.unavailable;
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 屏障层。AbsorbPointer 只能这样用：它包住的是这块空着色层，
          // 不是按钮。RenderAbsorbPointer.hitTest 在 absorbing 时直接
          // `return absorbing ? size.contains(position) : super.hitTest(…)`
          // ——自己认领命中点，压根不往下 hit-test 子树。原实现把整扇门
          // （含"解锁"按钮）塞进它的 child，于是按钮永远收不到点击，
          // 锁屏成了一块点不动的死屏（"显示一个锁，也不给解锁接口"）。
          //
          // 它同时提供 isBlockingUserActions，TalkBack 也操作不到下面的
          // 内容；Stack 的命中测试从最上层往下逐个问，这一层认领了剩下
          // 的位置，下面的界面既拿不到点击也拿不到滑动。
          AbsorbPointer(
            child: ColoredBox(
              color: cs.surface,
              child: const SizedBox.expand(),
            ),
          ),
          // 门本体：正常可点的交互层，盖在屏障之上。
          SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_rounded,
                      size: 64,
                      color: cs.primary.withValues(alpha: 0.6),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      l10n.appLockGateHint,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                    if (message != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: cs.error,
                            ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      // 认证系统弹窗打开期间禁用按钮，防止重复弹出。
                      // 卡死的可能由 didChangeAppLifecycleState 兜底清除。
                      onPressed: _authenticating ? null : _unlock,
                      icon: const Icon(Icons.fingerprint_rounded),
                      label: Text(l10n.unlock),
                    ),
                    if (credentialGone) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed:
                            _authenticating ? null : _disableLockAndUnlock,
                        child: Text(l10n.appLockTurnOffAndUnlock),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
