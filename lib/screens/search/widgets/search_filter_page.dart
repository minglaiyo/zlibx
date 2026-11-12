import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';

/// The values a filter-page visit returns when the user taps 使用.
/// Every field is carried for every caller (the page is initialised
/// from the caller's current values); the caller applies the ones it
/// shows, so fields a caller hides come back unchanged.
class SearchFilterResult {
  const SearchFilterResult({
    required this.language,
    required this.order,
    required this.extension,
    required this.yearFrom,
    required this.yearTo,
    required this.exact,
    required this.matchType,
    required this.contentType,
  });

  /// Language key (`all` = no language filter).
  final String language;

  /// Sort key (the mode's default means no sort filter).
  final String order;

  /// Extension key (`all` = no extension filter).
  final String extension;

  /// Year range bounds; null means that bound is unset.
  final int? yearFrom;
  final int? yearTo;

  /// Exact-match switch: the general search's `e=1` in general mode,
  /// the full-text exact flag in full-text mode.
  final bool exact;

  /// Full-text match type (`words` / `phrase`).
  final String matchType;

  /// Content type (`book` / `article`); null means any content type.
  /// Only the category caller shows this field.
  final String? contentType;
}

/// Full-screen filter page, modelled on the Z-Library site's own
/// filter page (issue #3): close discards, 使用 applies, 删除筛选
/// resets the staged values to the defaults.
///
/// Shared by the search screen and the category screen: each caller
/// picks which fields to show (search shows the mode's fields,
/// category shows exact match + years + language + extension +
/// content type) and applies the returned values its own way. Sort
/// is a page field only for search — the category screen keeps its
/// own sort dialog. The content-type values are the site's
/// `selected_content_types` form values (`book` / `article`, labels
/// confirmed from the site's own dropdown); the `article` value
/// matches the article-search route's `content_type=article`.
///
/// Staged editing: the page holds local copies of the values and only
/// hands them back through Navigator.pop when 使用 is tapped, so
/// closing with the ✕ leaves the applied filters untouched.
///
/// A dropdown shows the no-selection hint whenever its field sits at
/// its default (language / extension `all`, the configured default
/// sort, `words` match type, unset year) — the hint means "no filter
/// applied", and the default stays pickable in the list.
class SearchFilterPage extends StatefulWidget {
  const SearchFilterPage({
    super.key,
    required this.language,
    required this.order,
    required this.extension,
    required this.yearFrom,
    required this.yearTo,
    required this.exact,
    required this.matchType,
    required this.contentType,
    required this.languageNames,
    required this.orderNames,
    required this.extensionNames,
    required this.contentTypeNames,
    required this.defaultOrder,
    required this.showExact,
    required this.showMatchType,
    required this.showYears,
    required this.showLanguage,
    required this.showSort,
    required this.showExtension,
    required this.showContentType,
  });

  final String language;
  final String order;
  final String extension;
  final int? yearFrom;
  final int? yearTo;
  final bool exact;
  final String matchType;
  final String? contentType;
  final Map<String, String> languageNames;
  final Map<String, String> orderNames;
  final Map<String, String> extensionNames;
  final Map<String, String> contentTypeNames;

  /// The sort key that means "no sort filter" for this caller
  /// (`popular` for full-text search, `default` elsewhere).
  final String defaultOrder;

  /// Which fields the caller wants shown.
  final bool showExact;
  final bool showMatchType;
  final bool showYears;
  final bool showLanguage;
  final bool showSort;
  final bool showExtension;
  final bool showContentType;

  @override
  State<SearchFilterPage> createState() => _SearchFilterPageState();
}

class _SearchFilterPageState extends State<SearchFilterPage> {
  late String _language;
  late String _order;
  late String _extension;
  late int? _yearFrom;
  late int? _yearTo;
  late bool _exact;
  late String _matchType;
  late String? _contentType;

  @override
  void initState() {
    super.initState();
    _language = widget.language;
    _order = widget.order;
    _extension = widget.extension;
    _yearFrom = widget.yearFrom;
    _yearTo = widget.yearTo;
    _exact = widget.exact;
    _matchType = widget.matchType;
    _contentType = widget.contentType;
  }

  void _resetStaged() {
    setState(() {
      _language = 'all';
      _order = widget.defaultOrder;
      _extension = 'all';
      _yearFrom = null;
      _yearTo = null;
      _exact = false;
      _matchType = 'words';
      _contentType = null;
    });
  }

  void _apply() {
    Navigator.of(context).pop(
      SearchFilterResult(
        language: _language,
        order: _order,
        extension: _extension,
        yearFrom: _yearFrom,
        yearTo: _yearTo,
        exact: _exact,
        matchType: _matchType,
        contentType: _contentType,
      ),
    );
  }

  Widget _dropdownField<T>({
    required String label,
    required T? value,
    // A null entry renders as the no-selection label, so a picked
    // value can always be cleared back to unset (the year dropdowns
    // rely on this — their default is null, not a list entry).
    required List<T?> options,
    required String Function(T? option) display,
    required ValueChanged<T?> onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<T>(
          value: value,
          isExpanded: true,
          decoration: InputDecoration(
            hintText: l10n.noSelection,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
          ),
          items: [
            for (final option in options)
              DropdownMenuItem<T>(
                value: option,
                child: Text(display(option)),
              ),
          ],
          onChanged: onChanged,
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final years = <int>[
      for (var y = DateTime.now().year; y >= 1800; y--) y,
    ];

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Header: ✕ on the left, centred title, balanced spacer.
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Text(
                      l10n.filter,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.showExact) ...[
                      SwitchListTile(
                        title: Text(l10n.exactMatch),
                        value: _exact,
                        contentPadding: EdgeInsets.zero,
                        onChanged: (value) =>
                            setState(() => _exact = value),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (widget.showMatchType)
                      _dropdownField<String>(
                        label: l10n.matchMode,
                        value: _matchType == 'words' ? null : _matchType,
                        options: const ['words', 'phrase'],
                        display: (option) => option == 'phrase'
                            ? l10n.matchByPhrase
                            : l10n.matchByWords,
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _matchType = value);
                          }
                        },
                      ),
                    if (widget.showYears) ...[
                      _dropdownField<int>(
                        label: l10n.yearFrom,
                        value: _yearFrom,
                        options: [null, ...years],
                        display: (year) =>
                            year == null ? l10n.noSelection : '$year',
                        onChanged: (value) =>
                            setState(() => _yearFrom = value),
                      ),
                      _dropdownField<int>(
                        label: l10n.yearTo,
                        value: _yearTo,
                        options: [null, ...years],
                        display: (year) =>
                            year == null ? l10n.noSelection : '$year',
                        onChanged: (value) =>
                            setState(() => _yearTo = value),
                      ),
                    ],
                    if (widget.showLanguage)
                      _dropdownField<String>(
                        label: l10n.language,
                        value: _language == 'all' ? null : _language,
                        options: widget.languageNames.keys.toList(),
                        display: (key) => key == null
                            ? l10n.noSelection
                            : (widget.languageNames[key] ?? key),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _language = value);
                          }
                        },
                      ),
                    if (widget.showSort)
                      _dropdownField<String>(
                        label: l10n.sort,
                        value: _order == widget.defaultOrder ? null : _order,
                        options: widget.orderNames.keys.toList(),
                        display: (key) => key == null
                            ? l10n.noSelection
                            : (widget.orderNames[key] ?? key),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _order = value);
                          }
                        },
                      ),
                    if (widget.showExtension)
                      _dropdownField<String>(
                        label: l10n.extension,
                        value: _extension == 'all' ? null : _extension,
                        options: widget.extensionNames.keys.toList(),
                        display: (key) => key == null
                            ? l10n.noSelection
                            : (widget.extensionNames[key] ?? key),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _extension = value);
                          }
                        },
                      ),
                    if (widget.showContentType)
                      _dropdownField<String>(
                        label: l10n.contentType,
                        value: _contentType,
                        options: const [null, 'book', 'article'],
                        display: (value) => value == null
                            ? l10n.noSelection
                            : (widget.contentTypeNames[value] ?? value),
                        onChanged: (value) =>
                            setState(() => _contentType = value),
                      ),
                    // Clear row: resets the staged values only — the
                    // screen still applies nothing until 使用 is tapped.
                    TextButton.icon(
                      onPressed: _resetStaged,
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: Text(l10n.clearFilters),
                      style: TextButton.styleFrom(
                        foregroundColor: cs.onSurfaceVariant,
                        padding: EdgeInsets.zero,
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _apply,
                  child: Text(l10n.apply),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
