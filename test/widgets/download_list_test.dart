// P1-4 split tests: DownloadList (extracted from
// local_downloads_screen.dart's `_DownloadList`) renders the empty
// state and the flat list. Pumped directly with plain params plus a
// downloadTaskProvider override for the rows — no screen involved.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/download_provider.dart';
import 'package:zlibx/screens/downloads/widgets/download_list.dart';
import 'package:zlibx/widgets/empty_state.dart';

DownloadTask _task(String id, String title) => DownloadTask(
  id: id,
  book: Book(id: int.parse(id), title: title, author: 'A'),
  status: DownloadStatus.completed,
  downloadedAt: DateTime(2026, 11, 18, 10),
  fileSize: 1024,
);

Widget _app({required DownloadList list, List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: list),
    ),
  );
}

void main() {
  testWidgets('empty list renders the given empty state', (tester) async {
    await tester.pumpWidget(
      _app(
        list: const DownloadList(
          taskIds: [],
          emptyIcon: Icons.check_circle_outline_rounded,
          emptyTitle: 'Nothing here',
          emptyMessage: 'Nothing yet',
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('Nothing here'), findsOneWidget);
    expect(find.text('Nothing yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('flat list renders one row per task id', (tester) async {
    await tester.pumpWidget(
      _app(
        list: const DownloadList(
          taskIds: ['1', '2'],
          emptyIcon: Icons.check_circle_outline_rounded,
          emptyTitle: 'Nothing here',
          emptyMessage: 'Nothing yet',
        ),
        overrides: [
          downloadTaskProvider('1').overrideWithValue(_task('1', 'One')),
          downloadTaskProvider('2').overrideWithValue(_task('2', 'Two')),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('One'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('grouped list renders the rows under date headers',
      (tester) async {
    await tester.pumpWidget(
      _app(
        list: DownloadList(
          taskIds: const ['1'],
          groupDates: {'1': DateTime.now()},
          emptyIcon: Icons.check_circle_outline_rounded,
          emptyTitle: 'Nothing here',
          emptyMessage: 'Nothing yet',
        ),
        overrides: [
          downloadTaskProvider('1').overrideWithValue(_task('1', 'One')),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('One'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
