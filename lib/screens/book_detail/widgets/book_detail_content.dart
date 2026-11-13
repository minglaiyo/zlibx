import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/display_book.dart';

class BookDetailHeading extends StatelessWidget {
  final DisplayBook book;
  final String? subtitle;

  /// Tap handler for the author name: when set, the author reads as
  /// a link (it already uses the primary color) and opens a search
  /// for that author. Null means display-only.
  final VoidCallback? onAuthorTap;

  const BookDetailHeading({
    super.key,
    required this.book,
    this.subtitle,
    this.onAuthorTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (subtitle?.isNotEmpty ?? false) ...[
          Text(
            subtitle!,
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
        ],
        Text(
          book.title,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            height: 1.35,
            color: cs.onSurface,
          ),
        ),
        if (book.author?.isNotEmpty ?? false) ...[
          const SizedBox(height: 8),
          InkWell(
            onTap: onAuthorTap,
            borderRadius: BorderRadius.circular(4),
            child: Text(
              book.author!,
              style: TextStyle(
                fontSize: 15,
                height: 1.4,
                fontWeight: FontWeight.w500,
                color: cs.primary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class BookDetailTag extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool highlight;

  const BookDetailTag({
    super.key,
    required this.icon,
    required this.text,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = highlight ? cs.primary : cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: highlight
            ? cs.primary.withValues(alpha: 0.08)
            : cs.onSurface.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class BookDetailDescription extends StatefulWidget {
  final String text;

  const BookDetailDescription({super.key, required this.text});

  @override
  State<BookDetailDescription> createState() => _BookDetailDescriptionState();
}

class _BookDetailDescriptionState extends State<BookDetailDescription> {
  static const _previewLines = 6;
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant BookDetailDescription oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final style = theme.textTheme.bodyMedium!.copyWith(
      fontSize: 15,
      height: 1.7,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.localeOf(context),
          maxLines: _previewLines,
        )..layout(maxWidth: constraints.maxWidth);
        final canExpand = painter.didExceedMaxLines;
        painter.dispose();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.description,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              widget.text,
              style: style,
              maxLines: _expanded ? null : _previewLines,
              overflow: _expanded ? TextOverflow.clip : TextOverflow.ellipsis,
            ),
            if (canExpand)
              TextButton.icon(
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 18,
                ),
                label: Text(_expanded ? l10n.showLess : l10n.showMore),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size(48, 48),
                ),
              ),
          ],
        );
      },
    );
  }
}

class BookPublicationInfo extends StatelessWidget {
  final Map<String, String> fields;

  /// Tap handlers per field, keyed by the field label (the same
  /// string used as the map key in [fields]): a field with a handler
  /// renders its value as a link (primary color + ripple). A field
  /// without one stays plain text. Null means no field is tappable.
  final Map<String, VoidCallback>? onFieldTap;

  const BookPublicationInfo({
    super.key,
    required this.fields,
    this.onFieldTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entries = fields.entries.where(
      (entry) => entry.value.trim().isNotEmpty,
    );
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
        const SizedBox(height: 20),
        Text(
          AppLocalizations.of(context)!.publicationInfo,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 12),
        ...entries.map((entry) {
          // A field with a tap handler (publisher) reads as a link:
          // primary color + ripple. Other fields stay plain text.
          final onTap = onFieldTap?[entry.key];
          final value = Text(
            entry.value,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: onTap == null ? cs.onSurface : cs.primary,
            ),
          );
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 80,
                  child: Text(
                    entry.key,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: onTap == null
                      ? value
                      : InkWell(
                          onTap: onTap,
                          borderRadius: BorderRadius.circular(4),
                          child: value,
                        ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}
