import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'search_mode_selector.dart';

/// 从 search_screen 抽出的零状态段：镜像筛选页当前选择的可删除
/// chips —— 删一个即重置该筛并重新搜索（经 onReset* 回调交回
/// 搜索页）。
///
/// 只有当前模式真正发送的筛才有 chip：文章模式只显示排序；年份
/// 显示为一个合并 chip（`年份: 2020–2024`，单年只写一年，只设
/// 一端时开口），删它会同时清掉两端。
class SearchActiveFilterChips extends StatelessWidget {
  const SearchActiveFilterChips({
    super.key,
    required this.l10n,
    required this.mode,
    required this.languageNames,
    required this.orderNames,
    required this.extensionNames,
    required this.contentTypeNames,
    required this.selectedLanguage,
    required this.selectedOrder,
    required this.selectedExtension,
    required this.selectedYearFrom,
    required this.selectedYearTo,
    required this.exact,
    required this.selectedCategoryName,
    required this.selectedContentType,
    required this.onResetLanguage,
    required this.onResetOrder,
    required this.onResetExtension,
    required this.onResetYearFrom,
    required this.onResetYearTo,
    required this.onResetExact,
    required this.onResetCategory,
    required this.onResetContentType,
  });

  final AppLocalizations l10n;
  final SearchMode mode;
  final Map<String, String> languageNames;
  final Map<String, String> orderNames;
  final Map<String, String> extensionNames;
  final Map<String, String> contentTypeNames;
  final String selectedLanguage;
  final String selectedOrder;
  final String selectedExtension;
  final int? selectedYearFrom;
  final int? selectedYearTo;

  /// Exact-match flag of the current mode (general `e=1` or the
  /// full-text exact flag).
  final bool exact;

  /// Picked category's localized display name; null means no
  /// category filter (general mode only).
  final String? selectedCategoryName;

  /// Content-type filter inside a category (`book` / `article`);
  /// null means any content type.
  final String? selectedContentType;
  final VoidCallback onResetLanguage;
  final VoidCallback onResetOrder;
  final VoidCallback onResetExtension;
  final VoidCallback onResetYearFrom;
  final VoidCallback onResetYearTo;
  final VoidCallback onResetExact;
  final VoidCallback onResetCategory;
  final VoidCallback onResetContentType;

  /// The sort key that means "no sort filter" in the current mode —
  /// same default the badge in the search screen counts against.
  String get _defaultOrder =>
      mode == SearchMode.fulltext ? 'popular' : 'default';

  String _yearLabel() {
    final from = selectedYearFrom;
    final to = selectedYearTo;
    if (from != null && to != null) {
      if (from == to) return '${l10n.year}: $from';
      return '${l10n.year}: $from–$to';
    }
    if (from != null) return '${l10n.year}: $from–';
    return '${l10n.year}: –$to';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final chips = <Widget>[];

    void addChip(String label, VoidCallback onDeleted) {
      chips.add(
        InputChip(
          label: Text(label),
          onDeleted: onDeleted,
          deleteIconColor: cs.onPrimaryContainer,
          backgroundColor: cs.primaryContainer,
          side: BorderSide.none,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          labelStyle: TextStyle(
            color: cs.onPrimaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    // Article search sends only the query and sort, so only the sort
    // chip can appear there — the other filters are never applied.
    if (mode != SearchMode.article) {
      if (selectedCategoryName != null) {
        addChip(
          '${l10n.category}: $selectedCategoryName',
          onResetCategory,
        );
      }
      if (selectedContentType != null) {
        addChip(
          '${l10n.contentType}: ${contentTypeNames[selectedContentType]}',
          onResetContentType,
        );
      }
      if (selectedLanguage != 'all') {
        addChip(
          '${l10n.language}: ${languageNames[selectedLanguage]}',
          onResetLanguage,
        );
      }
      if (selectedExtension != 'all') {
        addChip(
          '${extensionNames[selectedExtension]}',
          onResetExtension,
        );
      }
      if (selectedYearFrom != null || selectedYearTo != null) {
        addChip(_yearLabel(), () {
          onResetYearFrom();
          onResetYearTo();
        });
      }
      if (exact) {
        addChip(l10n.exactMatch, onResetExact);
      }
    }
    if (selectedOrder != _defaultOrder) {
      addChip(
        '${l10n.sort}: ${orderNames[selectedOrder]}',
        onResetOrder,
      );
    }

    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: chips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, index) => chips[index],
      ),
    );
  }
}
