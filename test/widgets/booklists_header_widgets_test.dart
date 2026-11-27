// P1-4 split tests: BooklistsTypoTabs and BooklistSortDialog
// (extracted from booklists_screen.dart) keep their contracts: tapping
// a tab reports it, picking a sort row pops its order value.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/booklists_provider.dart';
import 'package:zlibx/screens/account/widgets/booklist_sort_dialog.dart';
import 'package:zlibx/screens/account/widgets/booklists_typo_tabs.dart';

void main() {
  testWidgets('typo tabs report the tapped tab', (tester) async {
    BooklistTab? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: BooklistsTypoTabs(
          active: BooklistTab.mine,
          labels: const {
            BooklistTab.mine: 'Mine',
            BooklistTab.favorite: 'Favorite',
            BooklistTab.discover: 'Discover',
          },
          onSelect: (tab) => selected = tab,
        ),
      ),
    );
    await tester.tap(find.text('Discover'));
    expect(selected, BooklistTab.discover);
    await tester.tap(find.text('Favorite'));
    expect(selected, BooklistTab.favorite);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sort dialog pops the picked order value', (tester) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await showDialog<String>(
                context: context,
                builder: (_) =>
                    const BooklistSortDialog(currentOrder: 'popular'),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Options are popular / date_created / date_updated in that order;
    // tap by index so the test does not depend on locale strings.
    expect(find.byType(ListTile), findsNWidgets(3));
    await tester.tap(find.byType(ListTile).at(1));
    await tester.pumpAndSettle();
    expect(picked, 'date_created');
    expect(tester.takeException(), isNull);
  });

  testWidgets('sort dialog cancel pops null', (tester) async {
    String? picked = 'unchanged';
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await showDialog<String>(
                context: context,
                builder: (_) =>
                    const BooklistSortDialog(currentOrder: 'popular'),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(picked, isNull);
    expect(tester.takeException(), isNull);
  });
}
