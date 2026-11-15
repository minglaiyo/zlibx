import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/screens/search/widgets/search_skeleton_grid.dart';
import 'package:zlibx/theme/app_layout.dart';

/// 搜索结果骨架网格的列数档位。
///
/// 自适应列数这个开关是要管到搜索页的：真正的结果网格
/// （search_results_view.dart 的 `_bookGrid`）和这里的骨架共用同一个
/// [BookCard.adaptiveGridDelegate]，加载完列数不能跳一下。结果网格要从
/// search_screen 的九个必填参数灌进测试成本高得多，所以钉骨架这一头：
/// 关掉时必须还是 `SliverGridDelegateWithMaxCrossAxisExtent`（= 旧版排布），
/// 打开时才换成按 AppLayout 估的固定列数。
Future<void> _pump(
  WidgetTester tester, {
  required bool adaptive,
  Size surface = const Size(600, 1200),
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SearchSkeletonGrid(adaptiveGridColumns: adaptive),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('关掉时保持旧的按最大卡宽估列数的委托', (tester) async {
    await _pump(tester, adaptive: false);
    final delegate =
        tester.widget<GridView>(find.byType(GridView)).gridDelegate;
    expect(delegate, isA<SliverGridDelegateWithMaxCrossAxisExtent>());
    expect(
      (delegate as SliverGridDelegateWithMaxCrossAxisExtent)
          .maxCrossAxisExtent,
      AppLayout.legacyMaxCardWidth,
    );
  });

  testWidgets('打开时 360dp 手机排三列（和首页同一档密度）', (tester) async {
    await _pump(tester, adaptive: true, surface: const Size(360, 800));
    final delegate =
        tester
            .widget<GridView>(find.byType(GridView))
            .gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开时 600dp 排四列', (tester) async {
    await _pump(tester, adaptive: true);
    final delegate =
        tester
            .widget<GridView>(find.byType(GridView))
            .gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    // 600dp：留白 32、内容 536dp，按 112dp 的下限排四列。
    expect(delegate.crossAxisCount, AppLayout.gridColumns(600));
    expect(delegate.crossAxisCount, 4);
    // 骨架和结果卡共用格高：mainAxisExtent 有值 = 走的是那个共用工厂，
    // 而不是本页自己再抄一份 childAspectRatio。
    expect(delegate.mainAxisExtent, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
