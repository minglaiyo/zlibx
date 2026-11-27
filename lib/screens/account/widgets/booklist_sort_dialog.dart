/// Single-choice sort dialog for the booklists screen (P1-4 split of
/// booklists_screen.dart). Pops the picked `order` value, or null when
/// cancelled.
import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';

/// Single-choice sort dialog, same idiom as the domain selector:
/// selected row = filled check in primary + bold primary title, tap
/// applies + closes. Pops the picked `order` value, or null when
/// cancelled.
class BooklistSortDialog extends StatelessWidget {
  final String currentOrder;

  const BooklistSortDialog({required this.currentOrder});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final options = <(String, String)>[
      ('popular', l10n.booklistSortPopular),
      ('date_created', l10n.booklistSortNewest),
      ('date_updated', l10n.booklistSortUpdated),
    ];
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      title: Text(l10n.booklistSort, style: const TextStyle(fontSize: 18)),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: options.length,
          itemBuilder: (context, index) {
            final (value, label) = options[index];
            final selected = value == currentOrder;
            return ListTile(
              dense: true,
              title: Text(
                label,
                style: selected
                    ? TextStyle(color: cs.primary, fontWeight: FontWeight.w700)
                    : null,
              ),
              trailing: Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
              onTap: () => Navigator.of(context).pop(value),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }
}
