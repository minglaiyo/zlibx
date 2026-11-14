// 隐私锁判定纯函数的行为测试：切后台回来的 shouldLockOnResume、冷启动
// 的 shouldLockOnColdStart——开关、超时档位、空记录 / 时钟回拨的边界。
// auth 与 Hive 不进测试——纯函数即可覆盖判定逻辑。
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

  // 冷启动判定。这一组测的是"上滑杀掉 / 被系统回收后重开"这条路：
  // 生命周期回调在这条路上根本不会给出 backgroundedAt，锁如果只靠
  // resumed 判定就等于没有（回归 bug：开着隐私锁也能直接进 app）。
  group('shouldLockOnColdStart', () {
    int msAt(Duration ago) => now.subtract(ago).millisecondsSinceEpoch;

    test('disabled never locks, even with a stale record', () {
      expect(
        shouldLockOnColdStart(
          enabled: false,
          timeoutSeconds: 0,
          leftForegroundAtMs: msAt(const Duration(hours: 3)),
          now: now,
        ),
        isFalse,
      );
    });

    test('no record at all locks (killed in the foreground)', () {
      expect(
        shouldLockOnColdStart(
          enabled: true,
          timeoutSeconds: 0,
          leftForegroundAtMs: null,
          now: now,
        ),
        isTrue,
      );
      // 延迟档位也一样：说不清什么时候离开的，就按需要验证处理。
      expect(
        shouldLockOnColdStart(
          enabled: true,
          timeoutSeconds: 300,
          leftForegroundAtMs: null,
          now: now,
        ),
        isTrue,
      );
    });

    test('immediate mode locks on any record', () {
      expect(
        shouldLockOnColdStart(
          enabled: true,
          timeoutSeconds: 0,
          leftForegroundAtMs: msAt(const Duration(seconds: 1)),
          now: now,
        ),
        isTrue,
      );
    });

    test('1-minute mode keeps the same grace window as resume', () {
      expect(
        shouldLockOnColdStart(
          enabled: true,
          timeoutSeconds: 60,
          leftForegroundAtMs: msAt(const Duration(seconds: 59)),
          now: now,
        ),
        isFalse,
      );
      expect(
        shouldLockOnColdStart(
          enabled: true,
          timeoutSeconds: 60,
          leftForegroundAtMs: msAt(const Duration(seconds: 60)),
          now: now,
        ),
        isTrue,
      );
    });

    test('a long absence always locks', () {
      expect(
        shouldLockOnColdStart(
          enabled: true,
          timeoutSeconds: 300,
          leftForegroundAtMs: msAt(const Duration(days: 2)),
          now: now,
        ),
        isTrue,
      );
    });

    test('a future record (clock rolled back) locks', () {
      expect(
        shouldLockOnColdStart(
          enabled: true,
          timeoutSeconds: 300,
          leftForegroundAtMs: now.add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
          now: now,
        ),
        isTrue,
      );
    });
  });
}
