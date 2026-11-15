import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/screens/search/widgets/search_skeleton_grid.dart';
import 'package:zlibx/theme/app_layout.dart';

/// 搜索结果骨架网格的列数档位。
///
/// 自适应列数这个开关是要管到搜索页的：真正的结果网格
/// （search_results_view.dart 的 `_bookGrid`）和这里的骨架共用同一套
/// 分支，加载完列数不能跳一下。结果网格要从 search_screen 的九个必填
/// 参数灌进测试成本高得多，而它的 delegate 与这里逐字相同，所以钉骨架
/// 这一头：关掉时必须还是 `SliverGridDelegateWithMaxCrossAxisExtent`
/// （= 旧版排布），打开时才换成按 AppLayout 估的固定列数。
Future<void> _pump(WidgetTester tester, {required bool adaptive}) async {
  await tester.binding.setSurfaceSize(const Size(600, 1200));
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

  testWidgets('打开时 600dp 排三列', (tester) async {
    await _pump(tester, adaptive: true);
    final delegate =
        tester
            .widget<GridView>(find.byType(GridView))
            .gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 3);
    expect(tester.takeException(), isNull);
  });
}
