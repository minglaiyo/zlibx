import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/books_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/update_provider.dart';
import '../../widgets/update_dialog.dart';
import '../../routes/app_routes.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../theme/app_metrics.dart';
import '../../utils/app_snack.dart';
import '../search/search_screen.dart';
import '../search/widgets/search_filter_dialog.dart';
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

  /// Pull-to-refresh: re-roll the random-category recommendations.
  /// Every refresh picks a new random category and page, so the grid
  /// always shows a different 50 books (user 2026-11-13: 每次刷新都换).
  Future<void> _refreshRecommendations() async {
    try {
      await ref.refresh(randomBooksProvider);
    } catch (_) {
      // The grid shows the error/retry branch; nothing more to do here.
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
            // Search Bar Trigger + quick links (category browse /
            // recently added). The pill keeps the full search gesture;
            // the two round buttons mirror its surface style.
            Row(
              children: [
                Expanded(child: _buildSearchPill(context, cs, searchBarHeight)),
                const SizedBox(width: 10),
                _HeaderIconButton(
                  icon: Icons.category_outlined,
                  tooltip: AppLocalizations.of(context)!.categoriesBrowse,
                  onTap: () => _openCategoryBrowse(context),
                ),
                const SizedBox(width: 8),
                _HeaderIconButton(
                  icon: Icons.fiber_new_rounded,
                  tooltip: AppLocalizations.of(context)!.recentlyAdded,
                  onTap: () => AppRoutes.openRecentBooks(context),
                ),
              ],
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

    final booksAsync = ref.watch(randomBooksProvider);

    return Column(
      children: [
        if (authState.lineUnavailable)
          const HomeLineUnavailableBanner(),
        Expanded(
          child: Stack(
            children: [
              HomeBookGrid(
                booksAsync: booksAsync,
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

  /// 搜索胶囊（原搜索触发条原样抽出，供首行 Row 与快捷按钮并排）。
  Widget _buildSearchPill(BuildContext context, ColorScheme cs, double height) {
    return GestureDetector(
      onTap: () => AppRoutes.openSearch(context),
      child: Container(
        height: height,
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
    );
  }

  /// 分类浏览：复用搜索筛选的分类树弹窗（841 项目录，本地化名 +
  /// 本地搜索），选中后直接进入该分类的浏览页（搜索屏的空查询
  /// 分类模式，含挑战墙回退）。选"全部分类"就是普通搜索。
  Future<void> _openCategoryBrowse(BuildContext context) async {
    final picked = await showDialog<PickedCategory?>(
      context: context,
      builder: (_) => const CategoryPickerDialog(currentId: null),
    );
    if (picked == null || !context.mounted) return;
    final id = picked.id;
    if (id == null) {
      await AppRoutes.openSearch(context);
      return;
    }
    await AppRoutes.openSearchWithCategory(
      context,
      SearchScreenArgs(
        categoryId: id,
        // 选中的分类一定带名字；类型上可空，兜底空串。
        categoryName: picked.name ?? '',
      ),
    );
  }
}

/// 首页头部的圆形快捷按钮：外观与搜索胶囊同款（surface 底 + 同色
/// 图标），用于分类浏览 / 最新上架两个入口。
class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(27),
          child: Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: cs.surface.withValues(alpha: 0.8),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Icon(icon, color: cs.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}
