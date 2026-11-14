import 'dart:async';
import 'dart:ui';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'services/app_lock_service.dart';
import 'services/challenge_html_cache.dart';
import 'services/webview_challenge_solver.dart';
import 'widgets/app_lock_overlay.dart';
import 'utils/diagnostics.dart';
import 'screens/challenge_solver/challenge_solver_screen.dart';
import 'l10n/generated/app_localizations.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Global error hooks (M2): uncaught async errors (e.g. inside an
  // unawaited(...) Future) and framework errors otherwise vanish
  // silently in a release + obfuscated build — the user only sees
  // "it doesn't work". logIgnored records only the tag + exception
  // TYPE + timestamp (never the message or URL), so nothing sensitive
  // reaches the ring log; Settings can dump it for bug reports.
  //
  // Debug: show the full error + stack on the console FIRST — the ring
  // log only keeps the exception type, which is not enough to debug.
  // Release: the ring log additionally records the topmost
  // `package:zlibx` frame (file:line) and, for network errors, the HTTP
  // status code — both data-free, see [Diagnostics.record].
  FlutterError.onError = (details) {
    if (kDebugMode) {
      FlutterError.presentError(details);
      debugPrint(details.stack.toString());
    }
    logIgnored('flutter', details.exception, stack: details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    if (kDebugMode) {
      debugPrint('Uncaught async error: $error');
      debugPrint(stack.toString());
    }
    logIgnored('platform', error, stack: stack);
    return true;
  };

  await HiveService.init();
  // Privacy lock companion: re-apply FLAG_SECURE from the persisted
  // setting (recents blur survives process restarts only if re-set).
  // A throwaway read — the notifier reads the same key later.
  final secureRecents = HiveService.settingsBox.get('secureRecents');
  if (secureRecents is bool && secureRecents) {
    unawaited(AppLockController.applySecureFlag(true));
  }
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
      MaterialPageRoute(
          builder: (_) => ChallengeSolverScreen(url: url)),
    );
    return solved == true ? ChallengeHtmlCache.get(url) : null;
  };

  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}


class _MyAppState extends ConsumerState<MyApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The plugin reports the raw HTML of every booklist page it
    // loads over Dio; persist it so the next open paints from cache
    // first (see BooklistHtmlCache). Registered once here: the
    // provider hands out one shared ZLibraryApi instance.
    // Account-scoped pages (own lists, detail pages) are stored
    // under the current account's partition, matching the keys the
    // screens read; public pages keep the plain URL key.
    ref.read(zlibraryApiProvider).onBooklistHtmlLoaded =
        (url, html, fetchedAt) {
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
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 隐私锁：paused 记时 / 立即锁，resumed 判定延迟锁是否到点。
    // 用 ref.read：不订阅开关本身，开关变化下次生命周期事件自然生效。
    final enabled = ref.read(appLockEnabledProvider);
    final timeoutSeconds = ref.read(appLockTimeoutProvider);
    final controller = AppLockController.instance;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        controller.handlePaused(
          enabled: enabled,
          timeoutSeconds: timeoutSeconds,
        );
      case AppLifecycleState.resumed:
        controller.handleResumed(
          enabled: enabled,
          timeoutSeconds: timeoutSeconds,
        );
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
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
          // 隐私锁覆盖层：盖在所有路由之上（builder 在 Navigator 外，
          // 所以路由切换不影响门闩）。
          builder: (context, child) =>
              AppLockOverlay(child: child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}
