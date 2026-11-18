import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/widgets/motion/motion.dart';

/// 动效组件族（v2 重写）的行为契约：
/// - 无障碍关闭动画时所有组件退化为静态 child（测试大量依赖这个
///   bypass：disableAnimations: true 是既有测试的通用前置）。
/// - 正常路径下入场自播一次、状态切换靠 key 触发。
Widget app(
  Widget child, {
  bool disableAnimations = false,
}) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: disableAnimations),
    child: Directionality(textDirection: TextDirection.ltr, child: child!),
  ),
  home: Scaffold(body: child),
);

void main() {
  group('MotionEntrance', () {
    testWidgets('入场自播一次：先透明后可见', (tester) async {
      await tester.pumpWidget(
        app(
          const MotionEntrance(index: 0, child: Text('item')),
        ),
      );
      // 首帧 t=0：完全透明。
      expect(
        tester.widget<Opacity>(find.byType(Opacity).first).opacity,
        0.0,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Opacity>(find.byType(Opacity).first).opacity,
        1.0,
      );
      expect(find.text('item'), findsOneWidget);
    });

    testWidgets('超档位（视口外懒加载项）直接显示不动画', (tester) async {
      await tester.pumpWidget(
        app(
          const MotionEntrance(index: 8, child: Text('offscreen')),
        ),
      );
      await tester.pump();
      // 没有 Opacity 包装 = 没有动画。
      expect(find.byType(Opacity), findsNothing);
      expect(find.text('offscreen'), findsOneWidget);
    });

    testWidgets('系统关闭动画：静态 child（既有测试依赖的 bypass）', (tester) async {
      await tester.pumpWidget(
        app(
          disableAnimations: true,
          const MotionEntrance(index: 0, child: Text('static')),
        ),
      );
      await tester.pump();
      expect(find.byType(Opacity), findsNothing);
      expect(find.text('static'), findsOneWidget);
    });
  });

  group('MotionSwitch', () {
    testWidgets('key 变化触发过渡（fade）', (tester) async {
      Widget host(bool flag) => app(
        MotionSwitch(
          child: Text(
            flag ? 'A' : 'B',
            key: ValueKey(flag),
          ),
        ),
      );
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      expect(find.text('A'), findsOneWidget);

      await tester.pumpWidget(host(false));
      // 过渡中：新旧两个 child 同时在场（exit 未完 + entry 进行）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('A'), findsNothing);
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('size 变体：高度随出现展开（search 头部折叠语义）', (tester) async {
      Widget host(bool visible) => app(
        SizedBox(
          height: 200,
          child: Column(
            children: [
              MotionSwitch(
                style: MotionSwitchStyle.size,
                child: visible
                    ? Container(
                        key: const ValueKey('row'),
                        height: 44,
                        color: Colors.red,
                      )
                    : const SizedBox.shrink(key: ValueKey('none')),
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const ValueKey('row'))).height, 44);

      await tester.pumpWidget(host(false));
      await tester.pumpAndSettle();
      // 收起后红块退场（transitionBuilder 会一直包着当前 child，
      // 所以不能断言 SizeTransition 不存在，要断言内容物退场）。
      expect(find.byKey(const ValueKey('row')), findsNothing);
    });

    testWidgets('系统关闭动画：时长归零，切换即时完成', (tester) async {
      Widget host(bool flag) => app(
        disableAnimations: true,
        MotionSwitch(
          child: Text(flag ? 'A' : 'B', key: ValueKey(flag)),
        ),
      );
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(false));
      await tester.pump();
      // 零时长：没有过渡中的双 child。
      expect(find.text('B'), findsOneWidget);
    });
  });

  group('Skeleton primitives', () {
    testWidgets('SkeletonBox 缺省取主题占位色', (tester) async {
      await tester.pumpWidget(
        app(const SkeletonBox(width: 40, height: 20)),
      );
      await tester.pump();
      // SkeletonBox 内部构建 Container；取它渲染出来的那个。
      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(SkeletonBox),
          matching: find.byType(Container),
        ),
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, isNotNull);
      expect(find.byType(SkeletonBox), findsOneWidget);
    });

    testWidgets('MotionShimmer：builder 收到共享动画且能构建', (tester) async {
      await tester.pumpWidget(
        app(
          MotionShimmer(
            builder: (context, animation) =>
                Text('v=${animation.value.toStringAsFixed(2)}'),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('v='), findsOneWidget);
      // 关闭动画时 shimmer 不 attach（值静止），但 builder 照常渲染。
      await tester.pumpWidget(
        app(
          disableAnimations: true,
          MotionShimmer(
            builder: (context, animation) =>
                Text('v=${animation.value.toStringAsFixed(2)}'),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('v='), findsOneWidget);
    });
  });
}
