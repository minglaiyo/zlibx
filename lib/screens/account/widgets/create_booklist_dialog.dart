import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/booklist_colors.dart';

/// Name + description + color + private form for a booklist. Pops a
/// record `(title, description, color, isPrivate)`, or null when
/// cancelled.
///
/// [isEdit] switches the dialog into edit mode: the title becomes
/// "Edit booklist", the submit button becomes "Save", and the fields
/// are prefilled from the given initial values. [initialColor] is the
/// site's 0–5 color, or null for "no color chosen yet" (create mode
/// defaults to 0, the site's first color).
class CreateBooklistDialog extends StatefulWidget {
  final String initialTitle;
  final String initialDescription;
  final int? initialColor;
  final bool initialPrivate;
  final bool isEdit;

  const CreateBooklistDialog({
    super.key,
    this.initialTitle = '',
    this.initialDescription = '',
    this.initialColor,
    this.initialPrivate = false,
    this.isEdit = false,
  });

  @override
  State<CreateBooklistDialog> createState() => CreateBooklistDialogState();
}

class CreateBooklistDialogState extends State<CreateBooklistDialog> {
  late final TextEditingController _titleController = TextEditingController(
    text: widget.initialTitle,
  );
  late final TextEditingController _descriptionController =
      TextEditingController(text: widget.initialDescription);
  late int _color = widget.initialColor ?? 0;
  late bool _isPrivate = widget.initialPrivate;

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    Navigator.of(context).pop((
      title: title,
      description: _descriptionController.text.trim(),
      color: _color,
      isPrivate: _isPrivate,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorNames = [
      l10n.booklistColorMarine,
      l10n.booklistColorVelvet,
      l10n.booklistColorNightBlue,
      l10n.booklistColorGreen,
      l10n.booklistColorYellow,
      l10n.booklistColorRed,
    ];
    return AlertDialog(
      title: Text(widget.isEdit ? l10n.booklistEdit : l10n.createBooklist),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _titleController,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(labelText: l10n.booklistTitle),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(
                labelText: l10n.booklistDescriptionOptional,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.booklistColor,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (var i = 0; i < BooklistColors.gradients.length; i++)
                  _ColorChip(
                    gradient: BooklistColors.gradientFor(i)!,
                    label: colorNames[i],
                    selected: _color == i,
                    onTap: () => setState(() => _color = i),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.booklistPrivate),
              value: _isPrivate,
              onChanged: (value) => setState(() => _isPrivate = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _titleController.text.trim().isEmpty ? null : _submit,
          child: Text(widget.isEdit ? l10n.save : l10n.create),
        ),
      ],
    );
  }
}

/// One round color swatch in the picker: the site's gradient, with a
/// check when selected.
class _ColorChip extends StatelessWidget {
  final LinearGradient gradient;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ColorChip({
    required this.gradient,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            gradient: gradient,
            shape: BoxShape.circle,
            border: selected
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  )
                : null,
          ),
          child: selected
              ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
              : null,
        ),
      ),
    );
  }
}
