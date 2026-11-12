import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_feed_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/update_provider.dart';
import '../../widgets/update_dialog.dart';
import '../../routes/app_routes.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../theme/app_metrics.dart';
import '../../utils/app_snack.dart';
import '../../widgets/liquid_nav_bar.dart';
import 'widgets/home_feed_view.dart';
import 'widgets/home_header_glass.dart';
import 'widgets/home_line_unavailable_banner.dart';

/// Get time-based greeting message
String _getGreeting(BuildContext context) {
  final hour = DateTime.now().hour;

  if (hour < 6) {
    return AppLocalizations.of(context)!.greetingLateNight;
  } else if (hour < 12) {
    return AppLocalizations.of(context)!.goodMorning;
  } else if (hour < 14) {
    return AppLocalizations.of(context)!.greetingNoon;
  } else if (hour < 18) {
    return AppLocalizations.of(context)!.greetingAfternoon;
  } else if (hour < 22) {
    return AppLocalizations.of(context)!.greetingEvening;
  } else {
    return AppLocalizations.of(context)!.greetingLateNight;
  }
}

class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key});

  @override
  ConsumerState<HomeTab> createState() => HomeTabState();
}

class HomeTabState extends ConsumerState<HomeTab> with WidgetsBindingObserver {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForUpdates();
      _maybeAutoRefresh();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _maybeAutoRefresh();
    }
  }

  /// Called when the Recommended tab becomes visible again.
  void onBecameVisible() => _maybeAutoRefresh();

  void _maybeAutoRefresh() {
    if (!mounted) return;
    final atTop = !_scrollController.hasClients || _scrollController.offset < 4;
    unawaited(ref.read(homeFeedProvider.notifier).autoRefresh(atTop: atTop));
  }

  /// Drives the floating nav bar's hide-on-scroll: hide while scrolling
  /// down, show while scrolling up, always show at the very top. Only
  /// applies while the floating bar and hide-on-scroll are both on.
  void _onScroll() {
    final hideEnabled =
        ref.read(floatingNavProvider) && ref.read(hideNavOnScrollProvider);
    if (!hideEnabled) {
      _setNavVisible(true);
      return;
    }
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels <= 0) {
      _setNavVisible(true);
      return;
    }
    if (position.userScrollDirection == ScrollDirection.reverse) {
      _setNavVisible(false);
    } else if (position.userScrollDirection == ScrollDirection.forward) {
      _setNavVisible(true);
    }

    if (position.pixels >= position.maxScrollExtent - 900) {
      unawaited(ref.read(homeFeedProvider.notifier).loadMore());
    }
  }

  void _setNavVisible(bool visible) {
    if (ref.read(navBarVisibleProvider) != visible) {
      ref.read(navBarVisibleProvider.notifier).setVisible(visible);
    }
  }

  /// Scroll the recommendation grid back to the top (used by the
  /// Recommended nav destination).
  void scrollToTop() {
    if (_scrollController.hasClients) {
      unawaited(
        _scrollController.animateTo(
          0,
          duration: AppMotion.slower,
          curve: Curves.easeOut,
        ),
      );
    }
  }

  Future<void> _refreshFeed() async {
    try {
      await ref.read(homeFeedProvider.notifier).refresh();
    } catch (_) {
      if (!mounted) return;
      showAppSnack(context, AppLocalizations.of(context)!.refreshFailed);
    }
  }

  Future<void> _checkForUpdates() async {
    final updateNotifier = ref.read(updateProvider.notifier);
    final hasUpdate = await updateNotifier.checkForUpdate();

    if (!hasUpdate || !mounted) return;

    if (ref.read(updateProvider).forceUpdate) {
      // Force update - non-dismissable dialog with download channels
      unawaited(showUpdateDialog(context));
    } else if (!updateNotifier.isVersionDismissed()) {
      // Normal update - show snackbar (non-intrusive)
      // 品牌视觉（图标行 + primary 背景 + 自定义 margin/shape）保留
      // 原生 SnackBar，只统一入口。
      showAppSnackRaw(
        context,
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.system_update, color: Colors.white, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  AppLocalizations.of(context)!.newVersionFound(
                    ref.read(updateProvider).latestVersion ?? '',
                  ),
                ),
              ),
            ],
          ),
          action: SnackBarAction(
            label: AppLocalizations.of(context)!.update,
            textColor: Colors.white,
            onPressed: () => showUpdateDialog(context),
          ),
          backgroundColor: Theme.of(context).colorScheme.primary,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: const Duration(seconds: 6),
          dismissDirection: DismissDirection.horizontal,
        ),
      );

      // Mark as shown (will show again next day)
      await updateNotifier.dismissUpdate();
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final user = authState.user;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final blurEnabled = ref.watch(blurEnabledProvider);
    final floatingNav = ref.watch(floatingNavProvider);

    // The glass header floats over the recommendation grid so the grid
    // scrolls underneath it (visible through the blur). Its height is
    // fixed, so the grid reserves the same space on top. When the
    // line-unavailable banner is shown it takes the status-bar inset
    // itself, so the header adds none.
    final topInset = authState.lineUnavailable
        ? 0.0
        : MediaQuery.of(context).padding.top;
    const searchBarHeight = 54.0;
    const headerPadding = 12.0;
    const greetingHeight = 58.0;
    const headerGap = 12.0;
    final headerHeight =
        topInset +
        headerPadding +
        searchBarHeight +
        headerGap +
        greetingHeight +
        headerPadding;
    // A little slack so the first row never tucks under the glass.
    final gridTopPadding = headerHeight + 8;

    // Header content (search bar + greeting). The blur is applied
    // around it only when the blur switch is on; otherwise the header
    // is a solid surface so nothing shows through.
    final header = Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        topInset + headerPadding,
        24,
        headerPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Search Bar Trigger
          GestureDetector(
            onTap: () => AppRoutes.openSearch(context),
            child: Container(
              height: searchBarHeight,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                color: cs.surface.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      AppLocalizations.of(context)!.searchForBooks,
                      style: TextStyle(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                        fontSize: 16,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(Icons.search, color: cs.onSurfaceVariant),
                ],
              ),
            ),
          ),

          const SizedBox(height: headerGap),

          // Greeting (below the search bar)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _getGreeting(context),
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                user?.name ?? (AppLocalizations.of(context)!.reader),
                style: theme.textTheme.displaySmall?.copyWith(
                  color: cs.onSurface,
                  fontWeight: FontWeight.bold,
                  fontSize: 28,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    final bottomPadding = LiquidNavBar.bottomClearance(
      context,
      floating: floatingNav,
    );

    return Column(
      children: [
        if (authState.lineUnavailable) const HomeLineUnavailableBanner(),
        Expanded(
          child: Stack(
            children: [
              HomeFeedView(
                scrollController: _scrollController,
                topPadding: gridTopPadding,
                bottomPadding: bottomPadding,
                onRefresh: _refreshFeed,
                onOpenBook: (book) =>
                    AppRoutes.openBookDetailForDisplayBook(context, book),
              ),
              // Progressive blur + a fading scrim, legado-style.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: HomeHeaderGlass(
                  height: headerHeight,
                  blurEnabled: blurEnabled,
                  surface: cs.surface,
                  child: header,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
