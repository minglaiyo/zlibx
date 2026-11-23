import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:quick_actions/quick_actions.dart';

import '../routes/app_routes.dart';
import '../screens/search/search_screen.dart';

/// App icon shortcuts (long-press the launcher icon): 扫码 / 搜索 /
/// 书单 / 我的图书馆.
///
/// Android only in practice — iOS has no launcher-icon shortcuts and
/// quick_actions is a no-op there. The four items are registered once
/// from [_MyAppState.initState]; tapping one navigates via the root
/// navigator. Cold start (the app launched from a shortcut) is
/// deferred: the splash screen replaces itself with home via
/// pushReplacement, which would swallow a route pushed on top of
/// splash, so a tap that lands before home has shown is stored as
/// [_pendingType] and drained by HomeScreen once home is showing.
/// [_homeShown] tells a warm tap (home already appeared, splash long
/// gone) from a cold one — warm taps navigate at once.
class AppShortcuts {
  AppShortcuts._();

  static const _scan = 'scan';
  static const _search = 'search';
  static const _booklists = 'booklists';
  static const _library = 'library';

  static GlobalKey<NavigatorState>? _navigatorKey;

  /// True once HomeScreen has appeared at least once (splash gone).
  static bool _homeShown = false;

  /// Shortcut type tapped before home showed (cold start). Drained
  /// by HomeScreen; cleared on read.
  static String? _pendingType;

  /// Register the four shortcuts and the tap handler. Call once from
  /// [_MyAppState.initState]. Awaits [QuickActions.initialize]: it
  /// pulls the launch action (the shortcut that cold-started the app,
  /// if any) via getLaunchAction, and that call throws when the engine
  /// has no Activity yet — fire-and-forget without a catch would drop
  /// the cold-start tap silently, so it is awaited here in try/catch.
  static Future<void> setup(GlobalKey<NavigatorState> navigatorKey) async {
    _navigatorKey = navigatorKey;
    const quickActions = QuickActions();
    try {
      await quickActions.initialize(_onShortcut);
    } catch (e) {
      // No Activity attached yet (cached engine / headless start):
      // the tap is lost for this launch; the handler is still
      // registered below for warm taps. Never crash startup over it.
      debugPrint('AppShortcuts initialize failed: $e');
    }
    await quickActions.setShortcutItems(const <ShortcutItem>[
      ShortcutItem(
        type: _scan,
        localizedTitle: '扫码',
        icon: 'ic_shortcut_scan',
      ),
      ShortcutItem(
        type: _search,
        localizedTitle: '搜索',
        icon: 'ic_shortcut_search',
      ),
      ShortcutItem(
        type: _booklists,
        localizedTitle: '书单',
        icon: 'ic_shortcut_booklists',
      ),
      ShortcutItem(
        type: _library,
        localizedTitle: '我的图书馆',
        icon: 'ic_shortcut_library',
      ),
    ]);
  }

  /// Called by HomeScreen once home is showing: mark splash gone and
  /// navigate to any shortcut tapped before that (cold start).
  static void markHomeShownAndDrain() {
    _homeShown = true;
    final type = _pendingType;
    if (type == null) return;
    _pendingType = null;
    _navigate(type);
  }

  static void _onShortcut(String type) {
    // Home never showed yet (cold start, still on splash or login):
    // hold it for HomeScreen to drain. Otherwise navigate at once.
    if (!_homeShown || !_navigate(type)) {
      _pendingType = type;
    }
  }

  /// Push the shortcut's page. Returns false when there is no
  /// navigator yet (cold start before the first frame).
  static bool _navigate(String type) {
    final navigator = _navigatorKey?.currentState;
    if (navigator == null) return false;
    switch (type) {
      case _scan:
        // The scanner pops with the ISBN; the shortcut has no caller
        // to receive it, so await it here and run the search with it
        // (instead of dropping the scan on the floor).
        unawaited(_scanThenSearch(navigator));
        break;
      case _search:
        navigator.pushNamed(AppRoutes.search);
        break;
      case _booklists:
        navigator.pushNamed(AppRoutes.booklists);
        break;
      case _library:
        navigator.pushNamed(AppRoutes.favorites);
        break;
      default:
        break;
    }
    return true;
  }

  /// Open the scanner, wait for the ISBN it pops with, then run the
  /// search with it. Backing out of the scanner (null/empty) just
  /// returns to where the user was.
  static Future<void> _scanThenSearch(NavigatorState navigator) async {
    final isbn = await navigator.pushNamed<String>(
      AppRoutes.barcodeScanner,
    );
    if (isbn == null || isbn.isEmpty) return;
    // Push directly on this navigator (Navigator.of on the
    // navigator's own context would look past it and find nothing).
    // Fire-and-forget: the search page owns its own result.
    unawaited(
      navigator.pushNamed(
        AppRoutes.search,
        arguments: SearchScreenArgs(query: isbn),
      ),
    );
  }
}
