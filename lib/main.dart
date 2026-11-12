import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'theme/app_theme.dart';
import 'providers/auth_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/zlibrary_provider.dart';
import 'routes/app_routes.dart';
import 'services/hive_service.dart';
import 'services/mirror_trust.dart';
import 'services/booklist_html_cache.dart';
import 'services/instance_manager.dart';
import 'services/storage_service.dart';
import 'services/challenge_html_cache.dart';
import 'services/webview_challenge_solver.dart';
import 'screens/challenge_solver/challenge_solver_screen.dart';
import 'l10n/generated/app_localizations.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Pre-compile the graduated header blur shader so the first home frame
  // does not fall back to a flat blur. Never throws.
  await ProgressiveBlur.preload();
  await HiveService.init();
  // Existing installs keep their current line without a trust prompt.
  await MirrorTrust.grandfatherCurrent();

  // One-time favorites migration: move the legacy shared
  // 'favorite_books' list to the account signed in right now (see
  // StorageService.migrateLegacyFavorites). Fire-and-forget and never
  // throws — if nobody is signed in yet it defers to the first
  // favorites access after login, and the per-operation guard in the
  // storage layer covers that path too.
  unawaited(StorageService().migrateLegacyFavorites());

  // Warm the Anna's Archive / LibGen mirror catalogue (open-slum.org) so
  // the first external search does not wait on it. refreshOnStartup is
  // the startup variant of InstanceManager.refresh(): it restores the
  // cached list first and never throws. Fire-and-forget on purpose —
  // startup must not block on the mirror list.
  unawaited(InstanceManager().refreshOnStartup());

  // When the headless challenge solve fails (e.g. a human CAPTCHA shows),
  // show the solver as a visible page over the current screen. The user
  // watches the check clear and the page closes itself as soon as the
  // HTML is captured; the caller then parses the cached HTML instead of
  // retrying a doomed Dio request. Registered here (before runApp) so it
  // is in place before any Anna search can run; the callback only uses
  // rootNavigatorKey when it is actually invoked.
  WebviewChallengeSolver.visibleSolverFallback = (url) async {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return null;
    final solved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ChallengeSolverScreen(url: url)),
    );
    return solved == true ? ChallengeHtmlCache.get(url) : null;
  };

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  @override
  void initState() {
    super.initState();
    // The plugin reports the raw HTML of every booklist page it
    // loads over Dio; persist it so the next open paints from cache
    // first (see BooklistHtmlCache). Registered once here: the
    // provider hands out one shared ZLibraryApi instance.
    // Account-scoped pages (own lists, detail pages) are stored
    // under the current account's partition, matching the keys the
    // screens read; public pages keep the plain URL key.
    ref
        .read(zlibraryApiProvider)
        .onBooklistHtmlLoaded = (url, html, fetchedAt) {
      final accountId = BooklistHtmlCache.isPrivateUrl(url)
          ? (ref.read(authProvider).user?.id ?? 'signed-out')
          : null;
      BooklistHtmlCache.store(
        url,
        html,
        accountId: accountId,
        fetchedAt: fetchedAt,
      );
    };
  }

  @override
  Widget build(BuildContext context) {
    final themeModeState = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);

    // Convert AppThemeMode to ThemeMode
    ThemeMode themeMode;
    switch (themeModeState) {
      case AppThemeMode.light:
        themeMode = ThemeMode.light;
      case AppThemeMode.dark:
        themeMode = ThemeMode.dark;
      case AppThemeMode.system:
        themeMode = ThemeMode.system;
    }

    // Material You dynamic color (Android 12+): the ColorScheme comes from
    // the wallpaper; where dynamic color is unavailable the schemes are
    // null and AppTheme falls back to the built-in palette.
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        return MaterialApp(
          navigatorKey: rootNavigatorKey,
          title: 'zlibx',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightThemeFromScheme(lightDynamic),
          darkTheme: AppTheme.darkThemeFromScheme(darkDynamic),
          themeMode: themeMode,

          // Localization
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          // The generated list (app delegate + GlobalMaterial +
          // GlobalCupertino + GlobalWidgets). Passing only
          // [AppLocalizations.delegate] would trip the debug-only
          // _debugCheckLocalizations assert for any non-English
          // locale, because MaterialApp appends English-only
          // DefaultMaterial/DefaultCupertino delegates.
          localizationsDelegates: AppLocalizations.localizationsDelegates,

          initialRoute: AppRoutes.splash,
          routes: buildAppRoutes(),
        );
      },
    );
  }
}
