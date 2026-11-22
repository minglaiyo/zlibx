import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/settings_provider.dart';
import 'section_header.dart';
import 'settings_card.dart';

/// Blocked keywords: search results whose title, author or publisher
/// contains any entry (case-insensitive substring) are hidden. Applies
/// to new searches; results already on screen are untouched.
class BlockedKeywordsSection extends ConsumerStatefulWidget {
  const BlockedKeywordsSection({super.key});

  @override
  ConsumerState<BlockedKeywordsSection> createState() =>
      _BlockedKeywordsSectionState();
}

class _BlockedKeywordsSectionState
    extends ConsumerState<BlockedKeywordsSection> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    ref.read(blockedKeywordsProvider.notifier).addKeyword(value);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final keywords = ref.watch(blockedKeywordsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        SectionHeader(
          icon: Icons.block_rounded,
          title: l10n.blockedKeywords,
        ),
        SettingsCard(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.blockedKeywordsDesc,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        decoration: InputDecoration(
                          hintText: l10n.blockedKeywordsHint,
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _add(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _add,
                      tooltip: l10n.add,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                if (keywords.isEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.blockedKeywordsEmpty,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: keywords
                        .map(
                          (keyword) => InputChip(
                            label: Text(keyword),
                            onDeleted: () => ref
                                .read(blockedKeywordsProvider.notifier)
                                .removeKeyword(keyword),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
