import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/settings_provider.dart';
import '../../../services/app_lock_service.dart';
import '../../../utils/app_snack.dart';
import 'section_header.dart';
import 'settings_card.dart';

/// 隐私锁设置区（用户批 2026-11-14 功能）：生物识别 / 设备凭据解锁。
/// 锁定逻辑在 [AppLockController]，生命周期钩子在
/// main.dart；这里只管开关与参数。
class PrivacySection extends ConsumerStatefulWidget {
  const PrivacySection({super.key});

  @override
  ConsumerState<PrivacySection> createState() => _PrivacySectionState();
}

class _PrivacySectionState extends ConsumerState<PrivacySection> {
  /// 开启隐私锁前先探测设备能力：什么都没有时打开只会把自己锁在
  /// 门外（authenticate 会永远失败）。
  Future<void> _onToggleEnabled(bool value) async {
    final l10n = AppLocalizations.of(context)!;
    if (value) {
      final can = await AppLockController.instance.canAuthenticate();
      if (!can) {
        if (!mounted) return;
        // 专用文案：这里根本没走到验证那一步，提示"解锁失败"只会让人
        // 以为是手指没认出来。真实原因是机器上没有任何可用凭据（没设
        // 锁屏密码也没录生物识别），硬开等于把门焊死。
        showAppSnack(context, l10n.appLockNoAuthenticator, error: true);
        // 开关是受控组件，但 setEnabled 没被调用 → provider 状态没变
        // → 不会 rebuild。Switch 内部已经按点击乐观地翻到位了，于是
        // 出现"看着开着、其实没开"。强制重建一次，让它回到持久化真值。
        setState(() {});
        return;
      }
    }
    await ref.read(appLockEnabledProvider.notifier).setEnabled(value);
  }

  Future<void> _pickTimeout(int current) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final seconds in const [0, 60, 300])
              ListTile(
                leading: Icon(
                  current == seconds
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                ),
                title: Text(
                  switch (seconds) {
                    0 => l10n.lockImmediately,
                    60 => l10n.lockAfter1Min,
                    _ => l10n.lockAfter5Min,
                  },
                ),
                onTap: () => Navigator.pop(sheetContext, seconds),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || picked == current) return;
    await ref.read(appLockTimeoutProvider.notifier).setTimeout(picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final enabled = ref.watch(appLockEnabledProvider);
    final timeoutSeconds = ref.watch(appLockTimeoutProvider);
    final cs = Theme.of(context).colorScheme;

    final timeoutLabel = switch (timeoutSeconds) {
      0 => l10n.lockImmediately,
      60 => l10n.lockAfter1Min,
      _ => l10n.lockAfter5Min,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          icon: Icons.lock_person_rounded,
          title: l10n.privacyLock,
        ),
        SettingsCard(
          child: Column(
            children: [
              SwitchListTile(
                title: Text(l10n.appLockEnable),
                subtitle: Text(
                  l10n.appLockEnableDesc,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                value: enabled,
                isThreeLine: true,
                activeThumbColor: cs.primary,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                onChanged: (value) => _onToggleEnabled(value),
              ),
              if (enabled)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: const Icon(Icons.timer_outlined),
                  title: Text(l10n.appLockTimeout),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        timeoutLabel,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right_rounded, size: 20),
                    ],
                  ),
                  onTap: () => _pickTimeout(timeoutSeconds),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
