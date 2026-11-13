// 隐私锁锁定判定（shouldLockOnResume）的行为测试：开关、超时档位、
// 空挂起时间的边界。auth 与 Hive 不进测试——纯函数即可覆盖判定逻辑。
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/app_lock_service.dart';

void main() {
  final now = DateTime(2026, 11, 14, 3, 0, 0);

  group('shouldLockOnResume', () {
    test('disabled never locks', () {
      expect(
        shouldLockOnResume(
          enabled: false,
          timeoutSeconds: 0,
          backgroundedAt: now.subtract(const Duration(hours: 1)),
          now: now,
        ),
        isFalse,
      );
    });

    test('no background time (never left foreground) never locks', () {
      expect(
        shouldLockOnResume(
          enabled: true,
          timeoutSeconds: 0,
          backgroundedAt: null,
          now: now,
        ),
        isFalse,
      );
    });

    test('immediate mode (0s) locks on any elapsed time', () {
      expect(
        shouldLockOnResume(
          enabled: true,
          timeoutSeconds: 0,
          backgroundedAt: now.subtract(const Duration(seconds: 1)),
          now: now,
        ),
        isTrue,
      );
    });

    test('1-minute mode unlocks within the window', () {
      expect(
        shouldLockOnResume(
          enabled: true,
          timeoutSeconds: 60,
          backgroundedAt: now.subtract(const Duration(seconds: 59)),
          now: now,
        ),
        isFalse,
      );
    });

    test('1-minute mode locks at and beyond the window', () {
      expect(
        shouldLockOnResume(
          enabled: true,
          timeoutSeconds: 60,
          backgroundedAt: now.subtract(const Duration(seconds: 60)),
          now: now,
        ),
        isTrue,
      );
      expect(
        shouldLockOnResume(
          enabled: true,
          timeoutSeconds: 60,
          backgroundedAt: now.subtract(const Duration(minutes: 5)),
          now: now,
        ),
        isTrue,
      );
    });

    test('5-minute mode unlocks within the window', () {
      expect(
        shouldLockOnResume(
          enabled: true,
          timeoutSeconds: 300,
          backgroundedAt: now.subtract(const Duration(minutes: 4, seconds: 59)),
          now: now,
        ),
        isFalse,
      );
    });
  });
}
