import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/models/display_book.dart';
import 'package:zlibx/routes/app_routes.dart';
import 'package:zlibx/screens/book_detail/book_detail_args.dart';

/// Routes whose screens need a typed arguments object. Opening any of them
/// with missing or mistyped arguments must show the plain fallback page,
/// not throw a cast error.
const _routesWithArgs = <String>[
  AppRoutes.bookDetail,
  AppRoutes.booklistDetail,
  AppRoutes.bookComments,
  AppRoutes.userProfile,
  AppRoutes.similarBooks,
  AppRoutes.reader,
];

/// Pumps an app whose home page has one button that pushes [route] with
/// [arguments], taps it and settles. The splash route is left out of the
/// table: `home` and a `/` route cannot both be set on MaterialApp.
Future<void> _openRoute(
  WidgetTester tester,
  String route,
  Object? arguments,
) async {
  final routes = buildAppRoutes()..remove(AppRoutes.splash);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        routes: routes,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () =>
                    Navigator.of(context).pushNamed(route, arguments: arguments),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final route in _routesWithArgs) {
    testWidgets('$route with missing arguments shows the fallback page', (
      tester,
    ) async {
      await _openRoute(tester, route, null);

      expect(find.text('Page unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$route with wrong-type arguments shows the fallback page', (
      tester,
    ) async {
      await _openRoute(tester, route, 42);

      expect(find.text('Page unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'bookDetail with BookDetailArgs(book: null) shows the fallback page',
    (tester) async {
      await _openRoute(
        tester,
        AppRoutes.bookDetail,
        const BookDetailArgs(book: null),
      );

      expect(find.text('Page unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bookDetail with a Z-Library DisplayBook that has no vendor Book '
    'shows the fallback page',
    (tester) async {
      await _openRoute(
        tester,
        AppRoutes.bookDetail,
        const BookDetailArgs.fromDisplayBook(
          displayBook: DisplayBook(
            id: 'no-original',
            title: 'No original',
            source: BookSource.zlibrary,
          ),
        ),
      );

      expect(find.text('Page unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
