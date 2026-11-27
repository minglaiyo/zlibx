// P1-4 split tests: BooklistsTabPage (extracted from
// booklists_screen.dart's `_page`) renders the loading skeleton, the
// logged-out and error states, and the ready list. Pumped directly
// with plain params — no providers involved.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/booklists_provider.dart';
import 'package:zlibx/screens/account/widgets/booklists_tab_page.dart';
import 'package:zlibx/widgets/booklist_card.dart';
import 'package:zlibx/widgets/empty_state.dart';

Booklist _list(String id) => Booklist(
  id: id,
  name: 'Synthetic List $id',
  author: 'Synthetic Author',
  count: 2,
  url: 'https://example.invalid/booklist/$id',
);

Widget _pump({
  required BooklistTab tab,
  required BooklistsState? state,
  required bool isLive,
  List<Booklist> recommendedLists = const [],
  VoidCallback? onRetry,
  VoidCallback? onLogin,
}) {
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  return MaterialApp(
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Builder(
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        return BooklistsTabPage(
          tab: tab,
          state: state,
          isLive: isLive,
          l10n: l10n,
          recommendedLists: recommendedLists,
          topPadding: 0,
          scrollController: scroll,
          onRefresh: () async {},
          onRetry: onRetry ?? () {},
          onLogin: onLogin ?? () {},
          onOpen: (_) {},
          onLongPress: (_) {},
        );
      },
    ),
  );
}

void main() {
  testWidgets('null state renders the loading skeleton', (tester) async {
    await tester.pumpWidget(
      _pump(tab: BooklistTab.mine, state: null, isLive: true),
    );
    await tester.pump();
    expect(find.byType(BooklistSkeletonList), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('logged-out state shows the login button', (tester) async {
    var loggedIn = false;
    await tester.pumpWidget(
      _pump(
        tab: BooklistTab.mine,
        state: const BooklistsState(phase: BooklistsPhase.loggedOut),
        isLive: true,
        onLogin: () => loggedIn = true,
      ),
    );
    await tester.pump();
    expect(find.byType(FilledButton), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    expect(loggedIn, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('error state shows the message and retries on tap (live)',
      (tester) async {
    var retried = false;
    await tester.pumpWidget(
      _pump(
        tab: BooklistTab.discover,
        state: const BooklistsState(
          phase: BooklistsPhase.error,
          error: 'boom',
        ),
        isLive: true,
        onRetry: () => retried = true,
      ),
    );
    await tester.pump();
    expect(find.text('boom'), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    expect(retried, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('error state on a neighbouring page has no retry button',
      (tester) async {
    await tester.pumpWidget(
      _pump(
        tab: BooklistTab.favorite,
        state: const BooklistsState(
          phase: BooklistsPhase.error,
          error: 'boom',
        ),
        isLive: false,
      ),
    );
    await tester.pump();
    expect(find.text('boom'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ready state with no lists shows the empty state',
      (tester) async {
    await tester.pumpWidget(
      _pump(
        tab: BooklistTab.mine,
        state: const BooklistsState(phase: BooklistsPhase.ready),
        isLive: true,
      ),
    );
    await tester.pump();
    expect(find.byType(EmptyState), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ready state renders the lists', (tester) async {
    await tester.pumpWidget(
      _pump(
        tab: BooklistTab.discover,
        state: BooklistsState(
          phase: BooklistsPhase.ready,
          lists: [_list('90001')],
        ),
        isLive: true,
      ),
    );
    await tester.pump();
    expect(find.text('Synthetic List 90001'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
