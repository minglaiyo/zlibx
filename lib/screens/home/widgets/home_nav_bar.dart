import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/settings_provider.dart';
import '../../../widgets/liquid_nav_bar.dart';

/// The four-destination liquid-glass bar. The host owns the PageController
/// and the current index; this widget only watches the bar's settings.
class HomeNavBar extends ConsumerWidget {
  const HomeNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.pageController,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final PageController pageController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final blurEnabled = ref.watch(blurEnabledProvider);
    final floatingNav = ref.watch(floatingNavProvider);
    final hideNavOnScroll = ref.watch(hideNavOnScrollProvider);
    final navVisible = ref.watch(navBarVisibleProvider);
    final refraction = ref.watch(glassRefractionProvider);
    final labelMode = ref.watch(navLabelModeProvider);
    final hideEnabled = floatingNav && hideNavOnScroll;

    return LiquidNavBar(
      destinations: <LiquidNavDestination>[
        LiquidNavDestination(
          icon: Icons.local_fire_department_outlined,
          selectedIcon: Icons.local_fire_department,
          label: t.recommended,
        ),
        LiquidNavDestination(
          icon: Icons.cloud_download_outlined,
          selectedIcon: Icons.cloud_download,
          label: t.downloads,
        ),
        LiquidNavDestination(
          icon: Icons.person_outlined,
          selectedIcon: Icons.person,
          label: t.account,
        ),
        LiquidNavDestination(
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings,
          label: t.settings,
        ),
      ],
      selectedIndex: selectedIndex,
      onSelected: onDestinationSelected,
      pageController: pageController,
      blurEnabled: blurEnabled,
      floating: floatingNav,
      refractionEnabled: refraction,
      labelMode: labelMode,
      visible: !hideEnabled || navVisible,
    );
  }
}
