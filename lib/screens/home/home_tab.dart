import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/books_provider.dart';
import '../../providers/zlibrary_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/update_provider.dart';
import '../../widgets/update_dialog.dart';
import '../../models/display_book.dart';
import '../../routes/app_routes.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../theme/app_metrics.dart';
import '../../utils/app_snack.dart';
import 'widgets/home_book_grid.dart';
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

class HomeTabState extends ConsumerState<HomeTab> {
  final _scrollController = ScrollController();

  /// Current popular-books page (0 = showing the personalised
  /// recommendations; >0 = showing popular page N). Pull-to-refresh
  /// pages through popular books because the personalised endpoint
  /// returns the same list every time.
  int _popularPage = 0;

  /// The popular page currently displayed, or null while showing the
  /// personalised recommendations.
  List<DisplayBook>? _pagedBooks;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Check for updates after frame is rendered
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForUpdates();
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
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
      unawaited(_scrollController.animateTo(
        0,
        duration: AppMotion.slower,
        curve: Curves.easeOut,
      ));
    }
  }

  /// Pull-to-refresh: show the next page of popular books. The
  /// personalised endpoint returns the same list every time, so paging
  /// popular is the only way a refresh shows genuinely different books.
  Future<void> _refreshRecommendations() async {
    await _loadPopularPage(_popularPage + 1);
  }

  Future<void> _loadPopularPage(int page) async {
    final api = ref.read(zlibraryApiProvider);
    final res = await api.search(order: 'popular', page: page, limit: 20);
    if (!mounted) return;
    final books = res.data;
    final totalPages = res.meta?['total_pages'];
    final outOfRange = totalPages is int && page > totalPages;
    if (!res.success || books == null || books.isEmpty || outOfRange) {
      // No more pages (or the fetch failed) — wrap back to page 1.
      if (page != 1) {
        await _loadPopularPage(1);
        return;
      }
      // Page 1 itself failed: nothing to wrap to — say so instead of
      // silently leaving the old list in place (a failed first refresh
      // otherwise looks exactly like a refresh that never fired).
      if (mounted && (!res.success || books == null)) {
        showAppSnack(
          context,
          AppLocalizations.of(context)!.refreshFailed,
        );
      }
      return;
    }
    setState(() {
      _popularPage = page;
      _pagedBooks = books.map((b) => b.toDisplay()).toList();
    });
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

    // The glass header floats over the recommendation grid so the grid
    // scrolls underneath it (visible through the blur). Its height is
    // fixed, so the grid reserves the same space on top. When the
    // line-unavailable banner is shown it takes the status-bar inset
    // itself, so the header adds none.
    final topInset =
        authState.lineUnavailable ? 0.0 : MediaQuery.of(context).padding.top;
    const searchBarHeight = 54.0;
    const headerPadding = 12.0;
    const greetingHeight = 58.0;
    const headerGap = 12.0;
    final headerHeight = topInset +
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
    final header = Container(
      decoration: BoxDecoration(
        color: blurEnabled ? cs.surface.withValues(alpha: 0.65) : cs.surface,
        border: Border(
          bottom: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            24, topInset + headerPadding, 24, headerPadding),
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
                          color:
                              cs.onSurfaceVariant.withValues(alpha: 0.7),
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
      ),
    );

    // When paging popular books, show the fetched page instead of the
    // personalised recommendations.
    final booksAsync = ref.watch(homeRecommendedProvider);
    final effectiveAsync = (_popularPage > 0 && _pagedBooks != null)
        ? AsyncValue.data(_pagedBooks!)
        : booksAsync;

    return Column(
      children: [
        if (authState.lineUnavailable)
          const HomeLineUnavailableBanner(),
        Expanded(
          child: Stack(
            children: [
              HomeBookGrid(
                booksAsync: effectiveAsync,
                topPadding: gridTopPadding,
                scrollController: _scrollController,
                onRefresh: _refreshRecommendations,
              ),
              // ========== 悬浮毛玻璃头部 ==========
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: blurEnabled
                    ? ClipRect(
                        child: BackdropFilter(
                          filter:
                              ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                          child: header,
                        ),
                      )
                    : header,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
