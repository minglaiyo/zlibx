import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/l10n/generated/app_localizations.dart';
import 'package:zlibx/providers/booklists_provider.dart';
import 'package:zlibx/providers/recommended_booklists_provider.dart';
import 'package:zlibx/screens/account/booklists_screen.dart';
import 'package:zlibx/widgets/booklist_card.dart';

/// Repro for the discover-tab grid-blank bug (device-verified 2026-11-11):
/// on the Discover booklists tab, list mode loads and shows the lists,
/// but tapping the grid-view toggle leaves the area below the sort row
/// blank, and the lists do not come back in list mode until the app is
/// killed and relaunched. The same grid renders fine on the own-lists
/// tab, so the test seeds discover-shaped data (color -1, synthetic
/// covers) and drives the real toggle.
///
/// The state is seeded by overriding both controllers the screen watches
/// with fakes that return a ready discover state, so no repository,
/// network or WebView solver ever runs. The fakes also no-op every
/// controller call the screen can reach (the scroll listener calls
/// `loadMore` whenever the remaining extent is under 300, which is
/// true whenever all content fits the viewport).

/// Ten discover-shaped fake lists: no color (`color: -1`, as the site
/// reports for lists that are not the signed-in user's own), a synthetic
/// cover URL that fails fast to the cards' error placeholder, and a
/// book count, so the grid card renders exactly as it would for real
/// discover data. No real URLs and no real tokens anywhere here.
List<Booklist> _fakeDiscoverLists() => [
      for (var i = 1; i <= 10; i++)
        Booklist(
          id: '9000$i',
          name: 'Synthetic List $i',
          author: 'Synthetic Author',
          count: 2 + i,
          color: -1,
          coverUrl: 'https://example.invalid/covers/$i.jpg',
          url: 'https://example.invalid/booklist/9000$i',
        ),
    ];

/// Fake main controller: returns the seeded ready discover state and
/// never touches the network. Every public call the screen can reach
/// is a no-op, so a scroll-listener `loadMore` or a stray `loadFirst`
/// cannot hit the real controller's uninitialised repository.
class _FakeBooklistsController extends BooklistsController {
  @override
  BooklistsState build() => BooklistsState(
        tab: BooklistTab.discover,
        phase: BooklistsPhase.ready,
        lists: _fakeDiscoverLists(),
        order: 'popular',
        nextPage: 2,
        hasMore: true,
      );

  @override
  Future<void> loadFirst() async {}

  @override
  Future<void> loadMore() async {}

  @override
  Future<void> refresh() async {}

  @override
  void search(String query) {}

  @override
  void setOrder(String order) {}

  @override
  void setTab(BooklistTab tab) {}
}

/// Fake recommendations controller: an empty section, so no real
/// recommended-booklists fetch runs and the grid assertion below only
/// counts the main list's tiles.
class _FakeRecommendedBooklistsController
    extends RecommendedBooklistsController {
  @override
  RecommendedBooklistsState build() =>
      const RecommendedBooklistsState(isLoading: false, lists: []);
}

/// Pumps the real screen on a surface tall enough for all ten grid
/// tiles to build (five rows at the 0.82 aspect ratio plus the header),
/// with the generated localizations delegates and animations disabled
/// so the pump can never hang on a repeating animation.
///
/// The toggle is a synchronous `setState` and the seeded state is
/// already in the provider, so a few frames are enough; the fake cover
/// URLs fail fast to the cards' error placeholders and the test never
/// waits on image loading.
Future<void> _pumpScreen(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(800, 3200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        booklistsControllerProvider.overrideWith(
          _FakeBooklistsController.new,
        ),
        recommendedBooklistsProvider.overrideWith(
          _FakeRecommendedBooklistsController.new,
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const BooklistsScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('discover list mode renders the seeded lists', (tester) async {
    await _pumpScreen(tester);
    // The seed actually reached the screen: all ten list cards paint,
    // with their names, and no grid tile is on screen yet.
    expect(find.byType(BooklistCard), findsNWidgets(10));
    expect(find.byType(BooklistGridCard), findsNothing);
    expect(find.text('Synthetic List 1'), findsOneWidget);
    expect(find.text('Synthetic List 10'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('grid toggle paints grid cards and back restores list cards',
      (tester) async {
    await _pumpScreen(tester);
    expect(find.byType(BooklistCard), findsNWidgets(10));

    // In list mode the toggle shows the grid icon; tapping it must
    // paint one grid tile per list and nothing else must throw.
    await tester.tap(find.byIcon(Icons.grid_view_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byIcon(Icons.view_list_rounded), findsOneWidget);
    expect(find.byType(BooklistGridCard), findsNWidgets(10));
    expect(find.byType(BooklistCard), findsNothing);
    expect(find.text('Synthetic List 1'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Tapping back must restore the list cards: on device the lists
    // did not come back after the grid tap until the app was killed
    // and relaunched, so this half of the round-trip is the bug too.
    await tester.tap(find.byIcon(Icons.view_list_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byIcon(Icons.grid_view_rounded), findsOneWidget);
    expect(find.byType(BooklistCard), findsNWidgets(10));
    expect(find.byType(BooklistGridCard), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
