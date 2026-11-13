import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
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

class _LockGate extends StatefulWidget {
  const _LockGate();

  @override
  State<_LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<_LockGate> {
  bool _authenticating = false;

  Future<void> _unlock() async {
    if (_authenticating) return;
    setState(() => _authenticating = true);
    try {
      final l10n = AppLocalizations.of(context)!;
      final ok = await AppLockController.instance
          .authenticate(l10n.appLockAuthReason);
      if (ok) {
        AppLockController.instance.unlock();
        return;
      }
      if (mounted) {
        showAppSnack(context, AppLocalizations.of(context)!.unlockFailed);
      }
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Positioned.fill(
      child: AbsorbPointer(
        // 锁住时不只是挡点击：覆盖层自己消费一切，下面的界面不可达。
        child: ColoredBox(
          color: cs.surface,
          child: SafeArea(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_rounded,
                    size: 64,
                    color: cs.primary.withValues(alpha: 0.6),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    // 认证系统弹窗打开期间禁用按钮，防止重复弹出。
                    onPressed: _authenticating ? null : _unlock,
                    icon: const Icon(Icons.fingerprint_rounded),
                    label: Text(l10n.unlock),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
