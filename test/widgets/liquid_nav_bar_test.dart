import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/models/nav_label_mode.dart';
import 'package:zlibx/widgets/liquid_nav_bar.dart';

const _destinations = <LiquidNavDestination>[
  LiquidNavDestination(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
    label: 'Home',
  ),
  LiquidNavDestination(
    icon: Icons.download_outlined,
    selectedIcon: Icons.download,
    label: 'Downloads',
  ),
  LiquidNavDestination(
    icon: Icons.person_outline,
    selectedIcon: Icons.person,
    label: 'Account',
  ),
  LiquidNavDestination(
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
    label: 'Settings',
  ),
];

void main() {
  testWidgets('each destination exposes a tappable semantic target', (
    tester,
  ) async {
    var selected = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: LiquidNavBar(
            destinations: _destinations,
            selectedIndex: 0,
            onSelected: (index) => selected = index,
            blurEnabled: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.bySemanticsLabel('Home'), findsOneWidget);
    expect(find.bySemanticsLabel('Downloads'), findsOneWidget);
    expect(find.bySemanticsLabel('Settings'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Downloads'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    expect(selected, 1);
  });

  testWidgets('tapping the active tab still notifies the caller', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: LiquidNavBar(
            destinations: _destinations,
            selectedIndex: 0,
            onSelected: (_) => taps++,
            blurEnabled: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.bySemanticsLabel('Home'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(taps, 1);
  });

  testWidgets('dragging the lens across icons selects the release target', (
    tester,
  ) async {
    var selected = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: LiquidNavBar(
            destinations: _destinations,
            selectedIndex: 0,
            onSelected: (index) => selected = index,
            blurEnabled: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final start = tester.getCenter(find.bySemanticsLabel('Home'));
    final end = tester.getCenter(find.bySemanticsLabel('Account'));
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveTo(end);
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));

    expect(selected, 2);
  });

  testWidgets('never mode hides labels but keeps semantic targets', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: LiquidNavBar(
            destinations: _destinations,
            selectedIndex: 0,
            onSelected: (_) => taps++,
            blurEnabled: false,
            labelMode: NavLabelMode.never,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Home'), findsNothing);
    expect(find.text('Downloads'), findsNothing);
    expect(find.bySemanticsLabel('Home'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Downloads'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(taps, 1);
  });

  testWidgets('auto mode shows only the selected label', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: LiquidNavBar(
            destinations: _destinations,
            selectedIndex: 0,
            onSelected: (_) {},
            blurEnabled: false,
            labelMode: NavLabelMode.auto,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // Both colour copies of the selected label are opaque; the other six
    // label copies stay in the tree (reserving space) at opacity 0.
    final opacities = tester
        .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
        .map((widget) => widget.opacity)
        .toList();
    expect(opacities.where((value) => value == 1).length, 3); // 2 labels + bar
    expect(opacities.where((value) => value == 0).length, 6);
  });

  testWidgets('optional refraction layer paints without errors', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: LiquidNavBar(
            destinations: _destinations,
            selectedIndex: 0,
            onSelected: (_) {},
            blurEnabled: true,
            refractionEnabled: true,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden bar stops receiving taps', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: LiquidNavBar(
            destinations: _destinations,
            selectedIndex: 0,
            onSelected: (_) => taps++,
            blurEnabled: false,
            visible: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.bySemanticsLabel('Downloads'), findsNothing);
  });
}
