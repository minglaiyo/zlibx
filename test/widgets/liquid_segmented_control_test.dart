import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/widgets/liquid_segmented_control.dart';

const _segments = <LiquidSegment>[
  LiquidSegment(icon: Icons.auto_stories_rounded, label: 'Z-Library'),
  LiquidSegment(icon: Icons.public_rounded, label: 'Anna'),
  LiquidSegment(icon: Icons.menu_book_rounded, label: 'LibGen'),
];

void main() {
  testWidgets('tapping and dragging move the source lens', (tester) async {
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: LiquidSegmentedControl(
                segments: _segments,
                selectedIndex: 0,
                onChanged: (index) => selected = index,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final rect = tester.getRect(find.byType(LiquidSegmentedControl));
    await tester.tapAt(Offset(rect.left + rect.width * 5 / 6, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 500));
    expect(selected, 2);

    selected = 0;
    await tester.dragFrom(
      Offset(rect.left + rect.width / 6, rect.center.dy),
      Offset(rect.width * 2 / 3, 0),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(selected, 2);
    expect(tester.takeException(), isNull);
  });
}
