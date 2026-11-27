import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bootstrap.dart';
import 'l10n/generated/app_localizations.dart';
import 'l10n/locale_resolution.dart';
import 'providers/auth_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/zlibrary_provider.dart';
import 'routes/app_routes.dart';
import 'services/app_lock_service.dart';
import 'services/app_shortcuts.dart';
import 'services/booklist_html_cache.dart';
import 'services/hive_service.dart';
import 'services/storage_service.dart';
import 'theme/app_theme.dart';
import 'widgets/app_lock_overlay.dart';
import 'widgets/update_progress_bar.dart';


final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── 120Hz 高刷新率适配 ────────────────────────────────────────────────
  // Flutter 引擎会自动检测设备能力并调整帧率。在支持 120Hz 的设备上，
  // 动画和滚动会更流畅。无需任何 AndroidManifest.xml 配置——Flutter
  // 引擎自动请求设备最高可用帧率（`preferredRefreshRate` 需要 API 31+，
  // 而本项目 minSdk=29，故不使用该属性）。
  //
  // 如需强制特定帧率（不推荐，会影响电量），可以取消注释：
  // SchedulerBinding.instance.setPreferredFramesPerSecond(120);

  installGlobalErrorHooks();

  await HiveService.init();
  registerRustParsers();
  registerBackgroundDownload();
  restoreAppLockOnStartup();
  await runStartupMigrations();
  warmCaches();
  registerChallengeSolverFallback(rootNavigatorKey);

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // App icon shortcuts (long-press the launcher icon): 扫码 / 搜索 /
    // 书单 / 我的图书馆. Registered once; taps navigate via the root
    // navigator, cold-start taps wait for HomeScreen to drain them.
    // setup is async (initialize pulls the cold-start launch action)
    // and must not block initState.
    unawaited(AppShortcuts.setup(rootNavigatorKey));
    // O2: open the heavier, non-first-frame boxes (booklist_html,
    // view_history) after the first frame paints, so their value
    // preload does not delay the splash. Fire-and-forget — callers
    // treat an unopened box as a cache miss until this settles.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        HiveService.initSecondary().then(
          (_) => StorageService.migrateSettingsToLibrary(),
        ),
      );
    });
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
          // O11: zh_TW / zh_HK / zh_MO shared the zh_Hant translations
          // (the three ARBs were byte-identical to zh_Hant apart from
          // @@locale). Map them to zh_Hant instead of carrying three
          // duplicate ~25 KB ARB files. Shared with the resolution test
          // via lib/l10n/locale_resolution.dart.
          localeListResolutionCallback: resolveAppLocale,
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
          // 所以路由切换不影响门闩）。全局更新进度条同样盖在这里，
          // 不依赖当前页面（计划一第 14 项）。
          builder: (context, child) => AppLockOverlay(
            child: Stack(
              children: [
                child ?? const SizedBox.shrink(),
                const UpdateProgressBar(),
              ],
            ),
          ),
        );
      },
    );
  }
}
