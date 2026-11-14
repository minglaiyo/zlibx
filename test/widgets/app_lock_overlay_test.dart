import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/services/app_lock_service.dart';
import 'package:zlibx/widgets/app_lock_overlay.dart';

/// 隐私锁锁门（AppLockOverlay / _LockGate）的回归测试。
///
/// 盯的是真实存在过的三个 bug：
/// 1. 门本体整棵子树包在 AbsorbPointer 里。RenderAbsorbPointer.hitTest
///    在 absorbing 时是 `return absorbing ? size.contains(position)
///    : super.hitTest(…)`——自己认领命中点，压根不往下 hit-test 子树，
///    于是"解锁"按钮收不到任何点击，锁屏成了一块点不动的死屏。
///    tester.tap 默认的 warnIfMissed 检查正是这条的探针。
/// 2. stickyAuth: true 时，弹窗期间 activity 被暂停会让 local_auth 既不
///    回调 Dart 也不注销监听（AuthenticationHelper 的 ERROR_CANCELED 分
///    支直接 return），那个 Future 永远挂着 → 按钮永久禁用。所以这里断
///    言传给 local_auth 的选项，以及失败后按钮必须重新可点。
/// 3. 失败提示走 SnackBar，而 SnackBar 画在路由的 Scaffold 里，被门这块
///    不透明 ColoredBox 完全盖住 → 用户看不到任何反馈。现在提示必须出现
///    在门的内部。
///
/// 真机插件在 flutter_test 里永远不会回包（authenticate 的 Future 直接
/// 挂死），所以用 [FakeLocalAuthentication] 从 AppLockController 的测试
/// 接缝注入。
const _innerKey = ValueKey<String>('locked-away-content');

/// 与 lib/l10n/app_en.arb 对齐的英文文案。写死是为了让断言不依赖
/// AppLocalizations 的解析结果——ARB 改了这里会红，正是想要的耦合。
const _unlockEn = 'Unlock';
const _unlockFailedEn = 'Unlock failed, please retry';
const _turnOffAndUnlockEn = 'Unlock and turn off privacy lock';

class FakeLocalAuthentication extends LocalAuthentication {
  FakeLocalAuthentication(this.outcome);

  /// true / false = 验证结果；其它值 = 抛出的异常。
  final Object outcome;
  int calls = 0;
  AuthenticationOptions? lastOptions;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<Object> authMessages = const <Object>[],
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    calls += 1;
    lastOptions = options;
    final Object result = outcome;
    if (result is bool) return result;
    throw result;
  }

  @override
  Future<bool> stopAuthentication() async => true;
}

Future<void> _pumpLocked(
  WidgetTester tester, {
  required bool locked,
  required VoidCallback onInnerTap,
  required FakeLocalAuthentication auth,
}) async {
  AppLockController.instance
    ..authClientForTest = auth
    ..locked.value = locked;
  addTearDown(() => AppLockController.instance.locked.value = false);
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // 与 main.dart 一致的挂法：builder 在 Navigator 外层，锁门盖住
        // 所有路由。
        builder: (context, child) =>
            AppLockOverlay(child: child ?? const SizedBox.shrink()),
        home: Scaffold(
          body: Center(
            child: GestureDetector(
              key: _innerKey,
              onTap: onInnerTap,
              child: const Text('INNER'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  late int taps;
  late FakeLocalAuthentication auth;

  setUp(() {
    taps = 0;
    auth = FakeLocalAuthentication(true);
  });

  Future<void> pump(WidgetTester tester, {bool locked = true}) => _pumpLocked(
        tester,
        locked: locked,
        onInnerTap: () => taps++,
        auth: auth,
      );

  group('AppLockOverlay', () {
    testWidgets('锁着时：门存在，且下面的内容点不到', (tester) async {
      await pump(tester);

      expect(find.text('INNER'), findsOneWidget);
      expect(find.text(_unlockEn), findsOneWidget);

      // warnIfMissed: false —— 这里就是要测"点不到"，不能让框架先报错。
      await tester.tap(find.byKey(_innerKey), warnIfMissed: false);
      await tester.pump();

      expect(taps, 0, reason: '屏障失效：被锁住的界面仍可操作');
      expect(auth.calls, 0, reason: '测试绑定首帧不是 resumed，不该自动弹验证');
    });

    testWidgets('没锁时：门不存在，内容正常可点', (tester) async {
      await pump(tester, locked: false);

      expect(find.text(_unlockEn), findsNothing);
      await tester.tap(find.byKey(_innerKey));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('解锁成功：门消失', (tester) async {
      auth = FakeLocalAuthentication(true);
      await pump(tester);

      // 默认 warnIfMissed：命中测试落不到按钮上就直接失败——这正是
      // AbsorbPointer 包住按钮那个 bug 的探针。
      await tester.tap(find.text(_unlockEn));
      await tester.pumpAndSettle();

      expect(auth.calls, 1);
      expect(AppLockController.instance.locked.value, isFalse);
      expect(find.text(_unlockEn), findsNothing);
      expect(find.text('INNER'), findsOneWidget);
    });

    testWidgets('解锁失败：提示写在门里，按钮仍可再点', (tester) async {
      auth = FakeLocalAuthentication(false);
      await pump(tester);

      await tester.tap(find.text(_unlockEn));
      await tester.pumpAndSettle();

      expect(
        find.text(_unlockFailedEn),
        findsOneWidget,
        reason: '失败提示必须画在门里——SnackBar 会被门本身盖住',
      );
      // 失败后必须能马上重试：曾经 stickyAuth 会让 Future 永远挂着，
      // 按钮就此永久禁用。
      expect(
        tester
            .widget<FilledButton>(find.byType(FilledButton))
            .onPressed,
        isNotNull,
      );

      await tester.tap(find.text(_unlockEn));
      await tester.pumpAndSettle();
      expect(auth.calls, 2);
    });

    testWidgets('设备凭据已消失：门里给出关闭隐私锁的出路', (tester) async {
      auth = FakeLocalAuthentication(
        PlatformException(code: 'NotEnrolled'),
      );
      await pump(tester);

      await tester.tap(find.text(_unlockEn));
      await tester.pumpAndSettle();

      // 出口按钮出现（不点：那条路径要写 Hive，超出本测试范围）。
      expect(find.text(_turnOffAndUnlockEn), findsOneWidget);
      expect(
        AppLockController.instance.locked.value,
        isTrue,
        reason: '光失败一次不该就把人放进去',
      );
    });

    testWidgets('传给 local_auth 的选项：不 sticky、不用插件自带弹窗',
        (tester) async {
      await pump(tester);

      await tester.tap(find.text(_unlockEn));
      await tester.pumpAndSettle();

      final options = auth.lastOptions!;
      // stickyAuth=true 会让 local_auth 在"弹窗期间被切后台"的路径上
      // 永不回调 Dart，锁门按钮永久禁用。
      expect(options.stickyAuth, isFalse);
      // 插件自带的"去设置"弹窗会把 app 推到后台，和锁门互相打断；
      // 错误文案由门自己显示。
      expect(options.useErrorDialogs, isFalse);
      // 允许退到锁屏密码，否则只有 PIN 的机器解不开。
      expect(options.biometricOnly, isFalse);
    });
  });
}
