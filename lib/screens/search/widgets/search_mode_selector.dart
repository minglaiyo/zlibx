import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/settings_provider.dart';
import '../../../widgets/liquid_segmented_control.dart';

/// The three search modes of the z站 search page. The enum lives here
/// (next to the switch that renders it); the screen owns the current
/// value and re-runs the query when it changes.
enum SearchMode { general, article, fulltext }

/// Three-way mode switch for the search page (通用搜索 / 文章 / 全文检索),
/// shown only for the z站 source. It uses the same draggable liquid lens as
/// the search-source selector and the bottom bar.
class SearchModeSelector extends ConsumerWidget {
  const SearchModeSelector({
    super.key,
    required this.l10n,
    required this.mode,
    required this.onSwitch,
  });

  final AppLocalizations l10n;
  final SearchMode mode;
  final ValueChanged<SearchMode> onSwitch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: LiquidSegmentedControl(
        segments: <LiquidSegment>[
          LiquidSegment(icon: Icons.search_rounded, label: l10n.generalSearch),
          LiquidSegment(icon: Icons.article_rounded, label: l10n.articleSearch),
          LiquidSegment(
            icon: Icons.find_in_page_rounded,
            label: l10n.fullTextSearch,
          ),
        ],
        selectedIndex: mode.index,
        onChanged: (index) => onSwitch(SearchMode.values[index]),
        glass: ref.watch(glassRefractionProvider),
      ),
    );
  }
}
