import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/booklist_colors.dart';

/// Single-choice color dialog for a booklist, following the
/// domain-selector idiom: dense rows, the selected row shows a filled
/// `check_circle` in primary with a bold primary title, unselected
/// rows a grey `circle_outlined`; tapping a row applies the color and
/// closes. Pops the picked color (0–5), or null when cancelled.
class BooklistColorDialog extends StatelessWidget {
  final int currentColor;

  const BooklistColorDialog({super.key, required this.currentColor});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final colorNames = [
      l10n.booklistColorMarine,
      l10n.booklistColorVelvet,
      l10n.booklistColorNightBlue,
      l10n.booklistColorGreen,
      l10n.booklistColorYellow,
      l10n.booklistColorRed,
    ];
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      title: Text(
        l10n.booklistChangeColor,
        style: const TextStyle(fontSize: 18),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: BooklistColors.gradients.length,
          itemBuilder: (context, index) {
            final selected = index == currentColor;
            final gradient = BooklistColors.gradientFor(index)!;
            return ListTile(
              dense: true,
              leading: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  gradient: gradient,
                  shape: BoxShape.circle,
                ),
              ),
              title: Text(
                colorNames[index],
                style: selected
                    ? TextStyle(color: cs.primary, fontWeight: FontWeight.w700)
                    : null,
              ),
              trailing: Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
              onTap: () => Navigator.of(context).pop(index),
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
