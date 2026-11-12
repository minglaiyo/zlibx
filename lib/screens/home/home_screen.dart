import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/zlibrary_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/booklist_warmup.dart';
import '../../widgets/keep_alive_page.dart';
import '../account/account_screen.dart';
import '../downloads/local_downloads_screen.dart';
import '../settings/settings_screen.dart';

import '../../theme/app_metrics.dart';
import 'home_tab.dart';
import 'widgets/home_nav_bar.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _selectedIndex = 0;
  final _homeTabKey = GlobalKey<HomeTabState>();
  final _pageController = PageController();

  @override
  void initState() {
    super.initState();
    // Fire-and-forget: warm the booklist pages' challenge solver in
    // the background so opening a booklist later skips the solve. The
    // home screen is the single funnel for signed-in entry (fresh
    // login and restored session both land here); the warm-up itself
    // is single-flight per launch, headless only, and silent on
    // failure.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        BooklistWarmup.warmUp(
          api: ref.read(zlibraryApiProvider),
          user: ref.read(authProvider).user,
        ),
      );
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Coolapk-style persistent tabs: all four destinations live in one
    // PageView under the same bottom nav (search is still opened from
    // the home search box, no nav tab). The first destination is
    // Recommended (the home tab, showing the recommendations); tapping
    // it scrolls the grid to the top. Previously downloads/account/
    // settings were pushed as routes and the nav bar disappeared.
    return PopScope(
      canPop: _selectedIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectedIndex != 0) {
          _pageController.animateToPage(
            0,
            duration: AppMotion.slow,
            curve: Curves.easeInOut,
          );
        }
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        extendBody: true,
        body: NotificationListener<ScrollNotification>(
          onNotification: _onTabScroll,
          child: PageView.builder(
            controller: _pageController,
            onPageChanged: (index) {
              // Switching tabs resets the nav to visible: a home tab
              // scrolled down must not leave the bar hidden on Settings.
              if (ref.read(navBarVisibleProvider) != true) {
                ref.read(navBarVisibleProvider.notifier).setVisible(true);
              }
              setState(() => _selectedIndex = index);
              if (index == 0) {
                _homeTabKey.currentState?.onBecameVisible();
              }
            },
            itemCount: 4,
            itemBuilder: (context, index) {
              // The builder only runs for the visible page and the
              // adjacent pages PageView prebuilds, so tabs the user has
              // not visited yet are not constructed at first frame.
              // Once built, each page stays alive via KeepAlivePage.
              if (index == 0) {
                return KeepAlivePage(
                  // No extra bottom padding here: the home grid already
                  // reserves 96 below its last row for the floating nav.
                  child: HomeTab(key: _homeTabKey),
                );
              }
              // No outer bottom padding on these tabs: like the home
              // grid, each tab reserves the floating nav's 96dp inside
              // its own scrollable content, so items scroll behind the
              // pill (and show through the blur) instead of stopping
              // at a fixed blank band above it.
              if (index == 1) {
                return const KeepAlivePage(child: LocalDownloadsScreen());
              }
              if (index == 2) {
                return const KeepAlivePage(child: AccountScreen());
              }
              return const KeepAlivePage(child: SettingsScreen());
            },
          ),
        ),
        bottomNavigationBar: HomeNavBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: _onDestinationSelected,
          pageController: _pageController,
        ),
      ),
    );
  }

  /// Hide-on-scroll for the Downloads / Account / Settings tabs. The
  /// Recommended tab drives the same provider from its own controller
  /// (see HomeTabState._onScroll), so it is skipped here. Only vertical
  /// scrolling counts: the PageView's own horizontal swipes and the
  /// Downloads TabBarView must not toggle the bar.
  bool _onTabScroll(ScrollNotification n) {
    if (_selectedIndex == 0 || n.metrics.axis != Axis.vertical) return false;
    final hideEnabled =
        ref.read(floatingNavProvider) && ref.read(hideNavOnScrollProvider);
    if (!hideEnabled) return false;
    void setVisible(bool v) {
      if (ref.read(navBarVisibleProvider) != v) {
        ref.read(navBarVisibleProvider.notifier).setVisible(v);
      }
    }

    if (n.metrics.pixels <= n.metrics.minScrollExtent) {
      setVisible(true);
    } else if (n is UserScrollNotification) {
      if (n.direction == ScrollDirection.reverse) {
        setVisible(false);
      } else if (n.direction == ScrollDirection.forward) {
        setVisible(true);
      }
    }
    return false;
  }

  void _onDestinationSelected(int index) {
    if (index == 0) {
      // Recommended: the home tab, scrolled to the top.
      _homeTabKey.currentState?.scrollToTop();
    }
    // The selected index follows the page (onPageChanged); tapping the
    // current tab leaves the page animation a no-op.
    _pageController.animateToPage(
      index,
      duration: AppMotion.slow,
      curve: Curves.easeInOut,
    );
  }
}
