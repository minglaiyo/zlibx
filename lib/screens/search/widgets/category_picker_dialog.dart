// 分类树选择弹窗（841 项目录，本地化名 + 本地搜索）——从
// search_filter_dialog.dart 拆出（审查批可维护性发现 12）：与分页筛选
// 弹窗无关，消费方是搜索空态与首页快捷入口。纯剪切迁移。
import 'package:flutter/material.dart';

import '../../../l10n/book_categories.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Searchable category picker over the 841 categories in
/// [kBookCategoryNames]: the "all categories" row first (unless
/// [showAllOption] is false), then every category in tree order —
/// top-level groups in bold with their subcategories indented
/// beneath. Typing filters locally by localized name or English
/// name, like the old tree screen's search; a matching subcategory
/// carries its parent group's name as a subtitle. Rows follow the
/// domain-selector idiom (current pick marked with a primary
/// `check_circle`).
/// One flat row of the category picker list.
typedef _PickerEntry = ({
  int id,
  String name,
  String? parentName,
  bool isTop,
});

class CategoryPickerDialog extends StatefulWidget {
  const CategoryPickerDialog({
    super.key,
    required this.currentId,
    this.showAllOption = true,
  });

  final int? currentId;

  /// Whether the "all categories" (clear) row is offered.
  final bool showAllOption;

  @override
  State<CategoryPickerDialog> createState() => _CategoryPickerDialogState();
}

class _CategoryPickerDialogState extends State<CategoryPickerDialog> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Every category in tree order: one row per group header, then all
  /// of its subcategories (no "show all" cap — the list is searchable
  /// and lazily built).
  List<_PickerEntry> _allEntries(Locale locale) {
    final entries = <_PickerEntry>[];
    for (final group in kBookCategoryGroups) {
      entries.add((
        id: group.top,
        name: bookCategoryDisplayName(group.top, locale),
        parentName: null,
        isTop: true,
      ));
      for (final id in group.subs) {
        entries.add((
          id: id,
          name: bookCategoryDisplayName(id, locale),
          parentName: null,
          isTop: false,
        ));
      }
    }
    return entries;
  }

  /// Matching categories, in tree order, with no cap. A match is a
  /// localized display name — or the English name — containing the
  /// query. Each matching subcategory carries its parent group's
  /// name as a subtitle (the grouping is lost in the flat filtered
  /// list).
  List<_PickerEntry> _filteredEntries(String query, Locale locale) {
    final needle = query.toLowerCase();
    bool matches(int id) {
      final display = bookCategoryDisplayName(id, locale).toLowerCase();
      if (display.contains(needle)) return true;
      final english = (kBookCategoryEnglishNames[id] ?? '').toLowerCase();
      return english.contains(needle);
    }

    final entries = <_PickerEntry>[];
    for (final group in kBookCategoryGroups) {
      if (matches(group.top)) {
        entries.add((
          id: group.top,
          name: bookCategoryDisplayName(group.top, locale),
          parentName: null,
          isTop: true,
        ));
      }
      for (final id in group.subs) {
        if (!matches(id)) continue;
        entries.add((
          id: id,
          name: bookCategoryDisplayName(id, locale),
          parentName: bookCategoryDisplayName(group.top, locale),
          isTop: false,
        ));
      }
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final locale = Localizations.localeOf(context);
    final filtering = _query.trim().isNotEmpty;
    final entries =
        filtering ? _filteredEntries(_query.trim(), locale) : _allEntries(locale);
    final showAll = widget.showAllOption && !filtering;

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      title: Text(
        l10n.categories,
        style: const TextStyle(fontSize: 18),
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: TextField(
                controller: _searchController,
                onChanged: (text) => setState(() => _query = text),
                decoration: InputDecoration(
                  hintText: l10n.searchCategories,
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: l10n.clear,
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(30),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                ),
              ),
            ),
            Expanded(
              child: filtering && entries.isEmpty
                  ? Center(child: Text(l10n.noResults))
                  : ListView.builder(
                      itemCount: entries.length + (showAll ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (showAll && index == 0) {
                          final selected = widget.currentId == null;
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              selected
                                  ? Icons.check_circle
                                  : Icons.circle_outlined,
                              color: selected
                                  ? cs.primary
                                  : cs.onSurfaceVariant,
                              size: 20,
                            ),
                            title: Text(
                              l10n.allCategories,
                              style: selected
                                  ? TextStyle(
                                      color: cs.primary,
                                      fontWeight: FontWeight.w700,
                                    )
                                  : null,
                            ),
                            onTap: () => Navigator.of(context)
                                .pop((id: null, name: null)),
                          );
                        }
                        final entry =
                            entries[index - (showAll ? 1 : 0)];
                        final selected = entry.id == widget.currentId;
                        return ListTile(
                          dense: true,
                          contentPadding: entry.isTop
                              ? null
                              : const EdgeInsets.only(left: 32, right: 16),
                          leading: Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            color: selected
                                ? cs.primary
                                : cs.onSurfaceVariant,
                            size: 20,
                          ),
                          title: Text(
                            entry.name,
                            style: TextStyle(
                              fontWeight: entry.isTop
                                  ? FontWeight.w700
                                  : FontWeight.normal,
                              color: selected ? cs.primary : null,
                            ),
                          ),
                          subtitle: entry.parentName == null
                              ? null
                              : Text(entry.parentName!),
                          onTap: () => Navigator.of(context).pop((
                            id: entry.id,
                            name: entry.name,
                          )),
                        );
                      },
                    ),
            ),
          ],
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

