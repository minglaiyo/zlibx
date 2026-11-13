import 'package:flutter/material.dart';

import 'category_picker_dialog.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../theme/app_metrics.dart';
import 'search_mode_selector.dart';

/// The values a filter-dialog visit returns when the user taps 使用.
/// Every field is carried for every visit (the dialog is initialised
/// from the caller's current values); the caller applies the ones it
/// shows, so fields it hides come back unchanged.
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
    required this.categoryId,
    required this.categoryName,
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
  /// Only offered while a category is picked.
  final String? contentType;

  /// Picked category id; null means no category filter.
  final int? categoryId;

  /// Picked category's localized display name; null with [categoryId].
  final String? categoryName;
}

/// Filter dialog for the search screen, in the app's dialog idiom
/// (the domain selector / sort dialog shape: dense rows, the current
/// value marked with a primary `check_circle` in a sub-dialog).
///
/// Replaces the old full-screen filter page (issue #3): the page
/// copied the site's own filter layout and read as a foreign screen;
/// this dialog keeps the same fields and the same staged editing
/// (edits apply only on 使用, 取消 discards, 删除筛选 resets the
/// staged values) in a popup that matches the rest of the app.
///
/// Which fields show is driven by the search [mode]: article shows
/// sort only (its request carries nothing else); full-text adds
/// exact match, match type, years, language and extension; general
/// adds exact match, years, language and extension plus the category
/// row (when [showCategory] is true — the z站 general search only)
/// and the content-type row, which appears only while a category is
/// picked (with the standard [AppMotion.standard] switch, the same
/// duration the domain dialog uses for its state swaps).
class SearchFilterDialog extends StatefulWidget {
  const SearchFilterDialog({
    super.key,
    required this.mode,
    required this.language,
    required this.order,
    required this.extension,
    required this.yearFrom,
    required this.yearTo,
    required this.exact,
    required this.matchType,
    required this.contentType,
    required this.categoryId,
    required this.categoryName,
    required this.languageNames,
    required this.orderNames,
    required this.extensionNames,
    required this.contentTypeNames,
    required this.defaultOrder,
    required this.showCategory,
  });

  final SearchMode mode;
  final String language;
  final String order;
  final String extension;
  final int? yearFrom;
  final int? yearTo;
  final bool exact;
  final String matchType;
  final String? contentType;
  final int? categoryId;
  final String? categoryName;
  final Map<String, String> languageNames;
  final Map<String, String> orderNames;
  final Map<String, String> extensionNames;
  final Map<String, String> contentTypeNames;

  /// The sort key that means "no sort filter" for this caller
  /// (`popular` for full-text search, `default` elsewhere).
  final String defaultOrder;

  /// Whether the category row is offered at all (z站 general search
  /// only — external sources have no category endpoint).
  final bool showCategory;

  @override
  State<SearchFilterDialog> createState() => _SearchFilterDialogState();
}

class _SearchFilterDialogState extends State<SearchFilterDialog> {
  late String _language;
  late String _order;
  late String _extension;
  late int? _yearFrom;
  late int? _yearTo;
  late bool _exact;
  late String _matchType;
  late String? _contentType;
  late int? _categoryId;
  late String? _categoryName;

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
    _categoryId = widget.categoryId;
    _categoryName = widget.categoryName;
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
      _categoryId = null;
      _categoryName = null;
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
        categoryId: _categoryId,
        categoryName: _categoryName,
      ),
    );
  }

  /// One single-choice sub-dialog in the domain-selector idiom: a
  /// dense row per option, the current one marked with a primary
  /// `check_circle`. Null is a valid pick ("no selection"), so the
  /// result says whether anything was picked at all — a dismissed
  /// dialog and a picked null must not look the same.
  Future<({bool picked, T? value})> _pickOne<T>({
    required String title,
    required T? current,
    required List<T?> options,
    required String Function(T? option) display,
  }) async {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final list = ListView.builder(
      shrinkWrap: options.length <= 12,
      itemCount: options.length,
      itemBuilder: (context, index) {
        final option = options[index];
        final selected = option == current;
        return ListTile(
          dense: true,
          title: Text(
            display(option),
            style: selected
                ? TextStyle(
                    color: cs.primary,
                    fontWeight: FontWeight.w700,
                  )
                : null,
          ),
          trailing: Icon(
            selected ? Icons.check_circle : Icons.circle_outlined,
            color: selected ? cs.primary : cs.onSurfaceVariant,
          ),
          onTap: () =>
              Navigator.of(context).pop((picked: true, value: option)),
        );
      },
    );
    final result = await showDialog<({bool picked, T? value})>(
      context: context,
      builder: (context) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        title: Text(title, style: const TextStyle(fontSize: 18)),
        content: options.length > 12
            ? SizedBox(
                width: double.maxFinite,
                height: MediaQuery.of(context).size.height * 0.55,
                child: list,
              )
            : SizedBox(width: double.maxFinite, child: list),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop((picked: false, value: null)),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
    return result ?? (picked: false, value: null);
  }

  Future<void> _pickCategory() async {
    final picked = await showDialog<PickedCategory?>(
      context: context,
      builder: (context) =>
          CategoryPickerDialog(currentId: _categoryId),
    );
    if (picked == null) return;
    setState(() {
      _categoryId = picked.id;
      _categoryName = picked.name;
      // Content type only exists inside a category: clearing the
      // category clears it too, so it can never leak into a later
      // unscoped search.
      if (_categoryId == null) _contentType = null;
    });
  }

  /// One filter field as a row: the label as the title, the current
  /// value as the subtitle, a chevron trailing — tapping opens the
  /// field's single-choice sub-dialog.
  Widget _fieldRow({
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      title: Text(label),
      subtitle: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: cs.onSurfaceVariant),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 20,
        color: cs.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final years = <int>[
      for (var y = DateTime.now().year; y >= 1800; y--) y,
    ];
    final isArticle = widget.mode == SearchMode.article;
    final isFulltext = widget.mode == SearchMode.fulltext;

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      title: Text(
        l10n.filter,
        style: const TextStyle(fontSize: 18),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isArticle)
                SwitchListTile(
                  title: Text(l10n.exactMatch),
                  value: _exact,
                  onChanged: (value) => setState(() => _exact = value),
                ),
              if (widget.showCategory)
                _fieldRow(
                  label: l10n.category,
                  value: _categoryName ?? l10n.allCategories,
                  onTap: _pickCategory,
                ),
              // Content type only makes sense inside a category: the
              // row fades in/out with the standard dialog swap
              // duration when the category is picked or cleared.
              AnimatedSwitcher(
                duration: AppMotion.standard,
                child: widget.showCategory && _categoryId != null
                    ? _fieldRow(
                        label: l10n.contentType,
                        value: _contentType == null
                            ? l10n.noSelection
                            : (widget.contentTypeNames[_contentType] ??
                                  _contentType!),
                        onTap: () async {
                          final picked = await _pickOne<String>(
                            title: l10n.contentType,
                            current: _contentType,
                            options: const [null, 'book', 'article'],
                            display: (value) => value == null
                                ? l10n.noSelection
                                : (widget.contentTypeNames[value] ?? value),
                          );
                          if (picked.picked) {
                            setState(() => _contentType = picked.value);
                          }
                        },
                      )
                    : const SizedBox.shrink(),
              ),
              if (isFulltext)
                _fieldRow(
                  label: l10n.matchMode,
                  value: _matchType == 'phrase'
                      ? l10n.matchByPhrase
                      : l10n.matchByWords,
                  onTap: () async {
                    final picked = await _pickOne<String>(
                      title: l10n.matchMode,
                      current: _matchType,
                      options: const ['words', 'phrase'],
                      display: (option) => option == 'phrase'
                          ? l10n.matchByPhrase
                          : l10n.matchByWords,
                    );
                    if (picked.picked && picked.value != null) {
                      setState(() => _matchType = picked.value!);
                    }
                  },
                ),
              if (!isArticle) ...[
                _fieldRow(
                  label: l10n.yearFrom,
                  value: _yearFrom == null ? l10n.noSelection : '$_yearFrom',
                  onTap: () async {
                    final picked = await _pickOne<int>(
                      title: l10n.yearFrom,
                      current: _yearFrom,
                      options: [null, ...years],
                      display: (year) =>
                          year == null ? l10n.noSelection : '$year',
                    );
                    if (picked.picked) {
                      setState(() => _yearFrom = picked.value);
                    }
                  },
                ),
                _fieldRow(
                  label: l10n.yearTo,
                  value: _yearTo == null ? l10n.noSelection : '$_yearTo',
                  onTap: () async {
                    final picked = await _pickOne<int>(
                      title: l10n.yearTo,
                      current: _yearTo,
                      options: [null, ...years],
                      display: (year) =>
                          year == null ? l10n.noSelection : '$year',
                    );
                    if (picked.picked) {
                      setState(() => _yearTo = picked.value);
                    }
                  },
                ),
                _fieldRow(
                  label: l10n.language,
                  value: widget.languageNames[_language] ?? _language,
                  onTap: () async {
                    final picked = await _pickOne<String>(
                      title: l10n.language,
                      current: _language,
                      options: widget.languageNames.keys.toList(),
                      display: (key) => key == null
                          ? l10n.noSelection
                          : (widget.languageNames[key] ?? key),
                    );
                    if (picked.picked && picked.value != null) {
                      setState(() => _language = picked.value!);
                    }
                  },
                ),
              ],
              _fieldRow(
                label: l10n.sort,
                value: widget.orderNames[_order] ?? _order,
                onTap: () async {
                  final picked = await _pickOne<String>(
                    title: l10n.sort,
                    current: _order,
                    options: widget.orderNames.keys.toList(),
                    display: (key) => key == null
                        ? l10n.noSelection
                        : (widget.orderNames[key] ?? key),
                  );
                  if (picked.picked && picked.value != null) {
                    setState(() => _order = picked.value!);
                  }
                },
              ),
              if (!isArticle)
                _fieldRow(
                  label: l10n.extension,
                  value: widget.extensionNames[_extension] ?? _extension,
                  onTap: () async {
                    final picked = await _pickOne<String>(
                      title: l10n.extension,
                      current: _extension,
                      options: widget.extensionNames.keys.toList(),
                      display: (key) => key == null
                          ? l10n.noSelection
                          : (widget.extensionNames[key] ?? key),
                    );
                    if (picked.picked && picked.value != null) {
                      setState(() => _extension = picked.value!);
                    }
                  },
                ),
              // Clear row: resets the staged values only — the screen
              // still applies nothing until 使用 is tapped.
              TextButton.icon(
                onPressed: _resetStaged,
                icon: const Icon(Icons.close_rounded, size: 18),
                label: Text(l10n.clearFilters),
                style: TextButton.styleFrom(
                  foregroundColor: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _apply,
          child: Text(l10n.apply),
        ),
      ],
    );
  }
}

/// What [CategoryPickerDialog] returns: the picked category (id plus
/// its localized display name), or an explicit "all categories" pick
/// (both fields null). A null future result means the dialog was
/// dismissed, not picked — the two must not look the same.
typedef PickedCategory = ({int? id, String? name});

