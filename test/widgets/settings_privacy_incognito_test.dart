import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/screens/settings/widgets/privacy_section.dart';
import 'package:zlibx/services/hive_service.dart';

/// 隐私设置区的无痕模式开关：只钉视觉与接线——两行开关的排布、
/// 开关初值来自 provider、点一下可见状态翻转。
///
/// 持久化与取值优先级在 `test/providers/incognito_mode_persistence_test.dart`
/// 里钉（普通 test() 通道）。这里拨动开关会触发真实 Hive put，而
/// testWidgets 的 FakeAsync 区里落盘 Future 永远不完成——所以
/// tearDown 绝不能 await Hive.close()（会挂到用例超时），库不关、
/// 临时目录不删，留给进程退出回收；临时目录每次新建，不复用。
Directory? hiveDir;

void main() {
  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('zlibx_privacy_test');
    Hive.init(hiveDir!.path);
    await Hive.openBox(HiveService.settingsBoxName);
  });

  tearDownAll(() {
    unawaited(Hive.close());
  });

  Widget app() => ProviderScope(
    child: MaterialApp(
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: SingleChildScrollView(child: PrivacySection())),
    ),
  );

  testWidgets('privacy section carries the incognito switch and it flips on tap', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // 两张卡、两行开关：应用锁在前，无痕模式在后；区块头已从
    // 「隐私锁」扩为「隐私」。
    expect(find.text('PRIVACY'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNWidgets(2));
    expect(find.text('Enable privacy lock'), findsOneWidget);
    expect(find.text('Incognito mode'), findsOneWidget);
    // 未打开过的 Hive 盒里没有这个键，默认关。
    final incognitoTile = tester.widget<SwitchListTile>(
      find.byType(SwitchListTile).last,
    );
    expect(incognitoTile.value, false);

    // 点一下：可见状态翻转（provider 内存态立即生效；落盘走
    // provider 测试的通道验证）。
    await tester.tap(find.text('Incognito mode'));
    await tester.pumpAndSettle();
    final flippedTile = tester.widget<SwitchListTile>(
      find.byType(SwitchListTile).last,
    );
    expect(flippedTile.value, true);
    expect(tester.takeException(), isNull);
  });
}
