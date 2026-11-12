import 'dart:ui';

import 'package:flutter/material.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../theme/app_metrics.dart';

/// The four-destination pill bar. HomeScreen owns the PageController and
/// passes the current index + selection callback in.
class HomeNavBar extends StatelessWidget {
  const HomeNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.blurEnabled,
    required this.floatingNav,
    required this.hideNavOnScroll,
    required this.navVisible,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final bool blurEnabled;
  final bool floatingNav;
  final bool hideNavOnScroll;
  final bool navVisible;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Coolapk-style destinations: the selected tab gets a primaryContainer
    // pill that wraps both the icon and the label (the fork's
    // LiquidNavigationBar does the same), instead of the M3 NavigationBar
    // indicator which only wraps the icon.
    // Nav order: Recommended / Downloads / Account / Settings. The
    // bookshelf used to be the second tab; it now lives inside the
    // account page as "My Library".
    const destinations = [
      (
        icon: Icons.local_fire_department_outlined,
        selectedIcon: Icons.local_fire_department,
        labelKey: 'recommended',
      ),
      (
        icon: Icons.cloud_download_outlined,
        selectedIcon: Icons.cloud_download,
        labelKey: 'downloads',
      ),
      (
        icon: Icons.person_outlined,
        selectedIcon: Icons.person,
        labelKey: 'account',
      ),
      (
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
        labelKey: 'settings',
      ),
    ];

    Widget navBar = Container(
      decoration: BoxDecoration(
        color: blurEnabled ? cs.surface.withValues(alpha: 0.7) : cs.surface,
        border: floatingNav
            ? null
            : Border(
                top: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
      ),
      child: SizedBox(
        height: 80,
        child: Row(
          children: [
            for (var i = 0; i < destinations.length; i++)
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 4,
                        ),
                        child: AnimatedOpacity(
                          opacity: selectedIndex == i ? 1.0 : 0.0,
                          duration: AppMotion.standard,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: cs.primaryContainer,
                              borderRadius: BorderRadius.circular(40),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => onDestinationSelected(i),
                          borderRadius: BorderRadius.circular(40),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                selectedIndex == i
                                    ? destinations[i].selectedIcon
                                    : destinations[i].icon,
                                color: selectedIndex == i
                                    ? cs.onPrimaryContainer
                                    : cs.onSurfaceVariant,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                switch (destinations[i].labelKey) {
                                  'downloads' =>
                                      AppLocalizations.of(context)!.downloads,
                                  'account' =>
                                      AppLocalizations.of(context)!.account,
                                  'settings' =>
                                      AppLocalizations.of(context)!.settings,
                                  _ =>
                                      AppLocalizations.of(context)!.recommended,
                                },
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: selectedIndex == i
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: selectedIndex == i
                                      ? cs.onPrimaryContainer
                                      : cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
    if (!blurEnabled) {
      navBar = _wrapNavBar(navBar, floatingNav);
    } else {
      navBar = ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: navBar,
        ),
      );
      navBar = _wrapNavBar(navBar, floatingNav);
    }
    // Hide on scroll down only applies to the floating bar; when the
    // feature is off the bar is always shown, whatever the transient
    // scroll state says.
    final hideEnabled = floatingNav && hideNavOnScroll;
    return AnimatedSlide(
      offset:
          hideEnabled && !navVisible ? const Offset(0, 1.5) : Offset.zero,
      duration: AppMotion.medium,
      curve: Curves.easeInOut,
      child: navBar,
    );
  }

  /// Floating style: detach the bar from the bottom edge as a rounded
  /// pill with a soft shadow. Non-floating keeps the full-width bar.
  /// Radius is half the NavigationBar height (80dp), i.e. a full pill —
  /// the same shape as Coolapk's floating bar (the c001apk fork's
  /// LiquidNavigationBar uses BorderRadius.circular(height / 2)).
  Widget _wrapNavBar(Widget navBar, bool floatingNav) {
    if (!floatingNav) return navBar;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(40),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(40),
        child: navBar,
      ),
    );
  }
}
