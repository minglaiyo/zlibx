import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/display_book.dart';
import '../../../providers/settings_provider.dart';
import '../../../widgets/liquid_segmented_control.dart';

/// Three-way search source picker. A single draggable liquid lens replaces
/// the three independently animated segments, so switching sources no longer
/// flickers and the glass setting is shared with the bottom bar.
class SearchSourceSelector extends ConsumerWidget {
  const SearchSourceSelector({
    super.key,
    required this.l10n,
    required this.selected,
    required this.onSwitch,
  });

  final AppLocalizations l10n;
  final BookSource selected;
  final ValueChanged<BookSource> onSwitch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = <BookSource>[
      BookSource.zlibrary,
      BookSource.annasArchive,
      BookSource.libgen,
    ];
    final icons = <BookSource, IconData>{
      BookSource.zlibrary: Icons.auto_stories_rounded,
      BookSource.annasArchive: Icons.public_rounded,
      BookSource.libgen: Icons.menu_book_rounded,
    };
    final labels = <BookSource, String>{
      BookSource.zlibrary: l10n.sourceZlibrary,
      BookSource.annasArchive: l10n.sourceAnnasArchive,
      BookSource.libgen: l10n.sourceLibgen,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: LiquidSegmentedControl(
        segments: <LiquidSegment>[
          for (final source in items)
            LiquidSegment(icon: icons[source]!, label: labels[source]!),
        ],
        selectedIndex: items.indexOf(selected),
        onChanged: (index) => onSwitch(items[index]),
        glass: ref.watch(glassRefractionProvider),
      ),
    );
  }
}
