import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/settings_provider.dart';
import 'section_header.dart';
import 'settings_card.dart';

/// Home layout: choose a 2- or 3-column book grid. The choice is persisted
/// in Hive and applied immediately by HomeFeedView.
class HomeLayoutSection extends ConsumerWidget {
  const HomeLayoutSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final t = AppLocalizations.of(context)!;
    final columns = ref.watch(homeGridColumnsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(icon: Icons.grid_view_rounded, title: t.homeLayout),
        SettingsCard(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.grid_view_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      t.gridColumns,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  segments: <ButtonSegment<int>>[
                    ButtonSegment<int>(value: 2, label: Text(t.twoColumns)),
                    ButtonSegment<int>(value: 3, label: Text(t.threeColumns)),
                  ],
                  selected: <int>{columns},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) {
                    unawaited(
                      ref
                          .read(homeGridColumnsProvider.notifier)
                          .setColumns(selection.first),
                    );
                  },
                  style: ButtonStyle(
                    side: const WidgetStatePropertyAll(BorderSide.none),
                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                      return states.contains(WidgetState.selected)
                          ? cs.primaryContainer
                          : cs.surfaceContainerHigh;
                    }),
                    foregroundColor: WidgetStateProperty.resolveWith((states) {
                      return states.contains(WidgetState.selected)
                          ? cs.onPrimaryContainer
                          : cs.onSurfaceVariant;
                    }),
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
