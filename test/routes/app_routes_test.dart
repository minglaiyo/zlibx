import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/routes/app_routes.dart';

void main() {
  group('buildAppRoutes', () {
    test('route table keys are exactly the AppRoutes constants', () {
      const expected = <String>{
        AppRoutes.splash,
        AppRoutes.login,
        AppRoutes.home,
        AppRoutes.search,
        AppRoutes.barcodeScanner,
        AppRoutes.bookDetail,
        AppRoutes.favorites,
        AppRoutes.history,
        AppRoutes.viewHistory,
        AppRoutes.recentBooks,
        AppRoutes.popularBooks,
        AppRoutes.similarBooks,
        AppRoutes.bookComments,
        AppRoutes.booklists,
        AppRoutes.booklistDetail,
        AppRoutes.relatedBooklists,
        AppRoutes.myComments,
        AppRoutes.userProfile,
        AppRoutes.reader,
        AppRoutes.settings,
        AppRoutes.downloads,
        AppRoutes.categoriesDirectory,
        AppRoutes.author,
      };

      final routes = buildAppRoutes();

      expect(expected.length, 23);
      expect(routes.keys.toSet(), expected);
      expect(routes.length, 23);
    });
  });
}
