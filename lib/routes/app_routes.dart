import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/display_book.dart';
import '../providers/auth_provider.dart';
import '../screens/account/booklist_detail_screen.dart';
import '../screens/account/booklists_screen.dart';
import '../screens/account/my_comments_screen.dart';
import '../screens/account/user_profile_screen.dart';
import '../screens/account/view_history_screen.dart';
import '../screens/auth/login_screen.dart';
import '../screens/downloads/local_downloads_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../services/view_history_storage.dart';
import '../screens/book_detail/book_detail_args.dart';
import '../screens/book_detail/book_detail_screen.dart';
import '../screens/comments/book_comments_screen.dart';
import '../screens/favorites/favorites_screen.dart';
import '../screens/home/home_screen.dart';
import '../screens/reader/reader_screen.dart';
import '../screens/recent/recent_books_screen.dart';
import '../screens/search/search_screen.dart';
import '../screens/settings/history_screen.dart';
import '../screens/similar/similar_books_screen.dart';
import '../screens/splash/splash_screen.dart';
import '../theme/app_metrics.dart';

class AppRoutes {
  static const String splash = '/';
  static const String login = '/login';
  static const String home = '/home';
  static const String search = '/search';
  static const String bookDetail = '/book-detail';
  static const String favorites = '/favorites';
  static const String history = '/history';
  static const String viewHistory = '/view-history';
  static const String recentBooks = '/recent-books';
  static const String similarBooks = '/similar-books';
  static const String bookComments = '/book-comments';
  static const String booklists = '/booklists';
  static const String booklistDetail = '/booklist-detail';
  static const String myComments = '/my-comments';
  static const String userProfile = '/user-profile';
  static const String reader = '/reader';
  static const String settings = '/settings';
  static const String downloads = '/downloads';

  // ── Typed navigation helpers (routes that take arguments) ──────────
  //
  // Each one is a single `pushNamed` with a statically typed `arguments:`
  // object, so a call site can no longer pass the wrong type. The route
  // table above and the receiving builders are unchanged; the string
  // route names stay underneath.

  /// Book detail page for an already-built [BookDetailArgs].
  static Future<T?> openBookDetail<T extends Object?>(
    BuildContext context,
    BookDetailArgs args,
  ) {
    // 浏览历史（官网"浏览历史"的本地实现）：所有详情入口都汇到这里，
    // 每次打开都置顶一条，与网站行为一致。只记站内书——Anna's
    // Archive / LibGen 的 DisplayBook 无法无损重建路由参数，不入历史。
    // 记录失败只进诊断日志，绝不影响打开详情页。
    final zBook = args.book ?? args.displayBook?.asZLibBook;
    if (zBook != null) ViewHistoryStore.add(zBook);
    return Navigator.of(context).pushNamed<T>(bookDetail, arguments: args);
  }

  /// Book detail page for a Z-Library vendor [Book].
  static Future<T?> openBookDetailForBook<T extends Object?>(
    BuildContext context,
    Book book,
  ) => openBookDetail<T>(context, BookDetailArgs(book: book));

  /// Book detail page for a unified [DisplayBook] (any source).
  ///
  /// A Z-Library [DisplayBook] carries its vendor [Book] in `original`;
  /// that is passed through as the Z-Library form so the detail page
  /// takes its Z-Library branch (a Z-Library [DisplayBook] wrapped with
  /// `BookDetailArgs.fromDisplayBook` has no `book`, and that branch
  /// reads `args.book`). Anna's Archive / LibGen items, and a
  /// Z-Library item whose `original` is missing, go through
  /// `BookDetailArgs.fromDisplayBook`.
  static Future<T?> openBookDetailForDisplayBook<T extends Object?>(
    BuildContext context,
    DisplayBook book, {
    String? unavailableReason,
  }) {
    final zBook = book.asZLibBook;
    return openBookDetail<T>(
      context,
      zBook != null
          ? BookDetailArgs(book: zBook, unavailableReason: unavailableReason)
          : BookDetailArgs.fromDisplayBook(
              displayBook: book,
              unavailableReason: unavailableReason,
            ),
    );
  }

  /// A booklist's detail page.
  static Future<T?> openBooklistDetail<T extends Object?>(
    BuildContext context,
    BooklistDetailArgs args,
  ) => Navigator.of(context).pushNamed<T>(booklistDetail, arguments: args);

  /// A book's comments page.
  static Future<T?> openBookComments<T extends Object?>(
    BuildContext context,
    BookCommentsArgs args,
  ) => Navigator.of(context).pushNamed<T>(bookComments, arguments: args);

  /// A user's profile page.
  static Future<T?> openUserProfile<T extends Object?>(
    BuildContext context,
    UserProfileArgs args,
  ) => Navigator.of(context).pushNamed<T>(userProfile, arguments: args);

  /// The similar-books page for one book.
  static Future<T?> openSimilarBooks<T extends Object?>(
    BuildContext context,
    SimilarBooksArgs args,
  ) => Navigator.of(context).pushNamed<T>(similarBooks, arguments: args);

  /// The in-app reader. [ReaderArgs.remixUserId] / [ReaderArgs.remixUserKey]
  /// are a session secret: they travel as route arguments only and must
  /// never be put into a URL.
  static Future<T?> openReader<T extends Object?>(
    BuildContext context,
    ReaderArgs args,
  ) => Navigator.of(context).pushNamed<T>(reader, arguments: args);

  // ── Typed navigation helpers (routes without arguments) ────────────

  /// The login page, pushed on top of the current page.
  static Future<T?> openLogin<T extends Object?>(BuildContext context) =>
      Navigator.of(context).pushNamed<T>(login);

  /// The home page, pushed on top of the current page. Not used by any
  /// caller yet (home is only ever reached by replacement, see
  /// [goHomeAfterLogin] / [splashToHome]); kept so every named route
  /// has a typed entry point.
  static Future<T?> openHome<T extends Object?>(BuildContext context) =>
      Navigator.of(context).pushNamed<T>(home);

  /// The search page.
  static Future<T?> openSearch<T extends Object?>(BuildContext context) =>
      Navigator.of(context).pushNamed<T>(search);

  /// The search page, scoped to one category: it opens browsing that
  /// category immediately. The category pages are gone — category
  /// lives only inside search now, so this is what the book-detail
  /// category chips navigate to.
  static Future<T?> openSearchWithCategory<T extends Object?>(
    BuildContext context,
    SearchScreenArgs args,
  ) => Navigator.of(context).pushNamed<T>(search, arguments: args);

  /// The search page, pre-filled with a query: it runs the search
  /// immediately. This is what the book-detail author/publisher taps
  /// navigate to.
  static Future<T?> openSearchWithQuery<T extends Object?>(
    BuildContext context,
    String query,
  ) => Navigator.of(context).pushNamed<T>(
    search,
    arguments: SearchScreenArgs(query: query),
  );

  /// The favorites page.
  static Future<T?> openFavorites<T extends Object?>(BuildContext context) =>
      Navigator.of(context).pushNamed<T>(favorites);

  /// The signed-in user's own comments page.
  static Future<T?> openMyComments<T extends Object?>(BuildContext context) =>
      Navigator.of(context).pushNamed<T>(myComments);

  /// The signed-in user's booklists page.
  static Future<T?> openBooklists<T extends Object?>(BuildContext context) =>
      Navigator.of(context).pushNamed<T>(booklists);

  /// The download-history page.
  static Future<T?> openHistory<T extends Object?>(BuildContext context) =>
      Navigator.of(context).pushNamed<T>(history);

  /// The local viewing-history page (books whose detail page was
  /// opened on this device).
  static Future<T?> openViewHistory<T extends Object?>(
    BuildContext context,
  ) => Navigator.of(context).pushNamed<T>(viewHistory);

  /// The recently-added books page (the site homepage's
  /// "new additions" section).
  static Future<T?> openRecentBooks<T extends Object?>(
    BuildContext context,
  ) => Navigator.of(context).pushNamed<T>(recentBooks);

  /// After a successful sign-in, or "skip login": replace the login page
  /// with the home page.
  static Future<T?> goHomeAfterLogin<T extends Object?>(
    BuildContext context,
  ) => Navigator.of(context).pushReplacementNamed<T, Object?>(home);

  /// After sign-out: go to the login page and clear the whole back stack
  /// (the predicate always returns false, so every route is removed).
  static Future<T?> logoutToLogin<T extends Object?>(BuildContext context) =>
      Navigator.of(context).pushNamedAndRemoveUntil<T>(
        login,
        (route) => false,
      );

  /// Splash exits with a fade, not a slide: the splash is full dark-green
  /// while home/login are full white, so a slide reads as a flash.
  /// (Moved verbatim from `SplashScreen._goHome`.)
  static Future<T?> splashToHome<T extends Object?>(BuildContext context) =>
      Navigator.of(context).pushReplacement<T, Object?>(
        PageRouteBuilder<T>(
          transitionDuration: AppMotion.slow,
          pageBuilder: (context, animation, secondaryAnimation) =>
              const HomeScreen(),
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) =>
                  FadeTransition(opacity: animation, child: child),
        ),
      );

  /// Same 300 ms fade as [splashToHome], into the login page.
  /// (Moved verbatim from `SplashScreen._goLogin`.)
  static Future<T?> splashToLogin<T extends Object?>(BuildContext context) =>
      Navigator.of(context).pushReplacement<T, Object?>(
        PageRouteBuilder<T>(
          transitionDuration: AppMotion.slow,
          pageBuilder: (context, animation, secondaryAnimation) =>
              const LoginScreen(),
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) =>
                  FadeTransition(opacity: animation, child: child),
        ),
      );
}

/// The app's named-route table (passed to `MaterialApp.routes`).
///
/// Moved verbatim out of `_MyAppState.build` in `main.dart` so the table
/// can be asserted in a test (see `test/routes/app_routes_test.dart`).
Map<String, WidgetBuilder> buildAppRoutes() {
  return {
    AppRoutes.splash: (context) => const SplashScreen(),
    AppRoutes.login: (context) => const LoginScreen(),
    AppRoutes.home: (context) => const HomeScreen(),
    AppRoutes.search: (context) {
      final args = ModalRoute.of(context)!.settings.arguments;
      if (args is SearchScreenArgs) {
        return SearchScreen(
          initialCategoryId: args.categoryId,
          initialCategoryName: args.categoryName,
          initialQuery: args.query,
        );
      }
      return const SearchScreen();
    },
    AppRoutes.bookDetail: (context) {
      final raw = ModalRoute.of(context)!.settings.arguments;
      // Normalize the calling forms into BookDetailArgs:
      //  - a BookDetailArgs (either form);
      //  - a DisplayBook (Anna's Archive / LibGen) or a vendor Book (z站,
      //    legacy callers).
      // Anything else (missing, wrong type) used to hit a bare `as Book`
      // cast and red-screen; show the plain fallback instead.
      final BookDetailArgs? args = raw is BookDetailArgs
          ? raw
          : raw is DisplayBook
          ? BookDetailArgs.fromDisplayBook(displayBook: raw)
          : raw is Book
          ? BookDetailArgs(book: raw)
          : null;
      // The detail page needs either an external (Anna's Archive /
      // LibGen) DisplayBook or a Z-Library Book; neither means the
      // arguments cannot be shown.
      if (args != null &&
          (args.isAnnasArchive || args.isLibGen || args.book != null)) {
        return BookDetailScreen(args: args);
      }
      return const _MissingRouteArgsScreen();
    },
    AppRoutes.favorites: (context) => const FavoritesScreen(),
    AppRoutes.history: (context) => const HistoryScreen(),
    // Settings and local downloads are bottom-nav tabs, but the forced
    // update dialog needs them as standalone pages (its escape hatch).
    // SettingsScreen has no inner Scaffold/AppBar, so the route supplies
    // the page chrome; LocalDownloadsScreen builds its own AppBar (with
    // a back button via automaticallyImplyLeading), so a bare Scaffold
    // is enough. Settings' list reserves 128dp at the bottom for the
    // floating nav this page does not have — harmless dead space.
    AppRoutes.settings: (context) => Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.settings),
      ),
      body: const SettingsScreen(),
    ),
    AppRoutes.downloads: (context) => const Scaffold(
      body: LocalDownloadsScreen(),
    ),
    AppRoutes.viewHistory: (context) => const ViewHistoryScreen(),
    AppRoutes.recentBooks: (context) => const RecentBooksScreen(),
    AppRoutes.similarBooks: (context) {
      final args = ModalRoute.of(context)!.settings.arguments;
      if (args is SimilarBooksArgs) {
        return SimilarBooksScreen(args: args);
      }
      return const _MissingRouteArgsScreen();
    },
    AppRoutes.bookComments: (context) {
      final args = ModalRoute.of(context)!.settings.arguments;
      if (args is BookCommentsArgs) {
        return BookCommentsScreen(args: args);
      }
      return const _MissingRouteArgsScreen();
    },
    AppRoutes.booklists: (context) => const BooklistsScreen(),
    AppRoutes.booklistDetail: (context) {
      final args = ModalRoute.of(context)!.settings.arguments;
      // A missing/mistyped arguments object (deep link, hot-reload
      // route change) used to throw an async type-cast error and
      // red-screen. Show a plain fallback instead.
      if (args is BooklistDetailArgs) {
        return BooklistDetailScreen(args: args);
      }
      return const _MissingRouteArgsScreen();
    },
    AppRoutes.myComments: (context) => const MyCommentsScreen(),
    AppRoutes.userProfile: (context) {
      final args = ModalRoute.of(context)!.settings.arguments;
      if (args is UserProfileArgs) {
        return UserProfileScreen(args: args);
      }
      return const _MissingRouteArgsScreen();
    },
    AppRoutes.reader: (context) {
      final args = ModalRoute.of(context)!.settings.arguments;
      if (args is ReaderArgs) {
        // 会话回同步：WebView 里的站内登录/密钥轮换要被 app 采纳，
        // 否则下次预览会把旧会话盖回去，站点反复弹登录墙。
        return Consumer(
          builder: (context, ref, _) => ReaderScreen(
            url: args.url,
            title: args.title,
            remixUserId: args.remixUserId,
            remixUserKey: args.remixUserKey,
            onSessionChanged: (userId, userKey) {
              unawaited(
                ref
                    .read(authProvider.notifier)
                    .adoptWebViewSession(userId, userKey),
              );
            },
          ),
        );
      }
      return const _MissingRouteArgsScreen();
    },
  };
}

/// Plain fallback for routes whose typed arguments are missing or of the
/// wrong type — see the guarded builders above.
class _MissingRouteArgsScreen extends StatelessWidget {
  const _MissingRouteArgsScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: Text(
          AppLocalizations.of(context)?.pageUnavailable ??
              'Page unavailable',
        ),
      ),
    );
  }
}

/// Arguments for the user profile page. The id drives the comments
/// fetch; name/avatar come from the tapped comment itself (the
/// comments endpoint carries no profile header). [userHash] is the
/// profile hash from the comment's `user.hash` — it drives the
/// booklists fetch (`/profile/{userId}/{hash}`); null when the
/// comment did not carry one, in which case the page shows comments
/// only. Kept here, next to the route, because the comments screen
/// (avatar tap) and the profile screen (row tap-through) navigate to
/// each other — a screen-local class would make those two files
/// import each other.
class UserProfileArgs {
  final int userId;
  final String userName;
  final String userAvatar;
  final String? userHash;

  const UserProfileArgs({
    required this.userId,
    required this.userName,
    required this.userAvatar,
    this.userHash,
  });
}
