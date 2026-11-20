import 'widgets/search_filter_dialog.dart';
import 'widgets/search_mode_selector.dart';

/// 搜索页的筛选/范围状态（审查 B2 拆分，2026-11-21）：纯字段 + 激活
/// 计数 + 筛选对话框结果回填，不带 Flutter 依赖。所有权归
/// SearchScreen；各"重置单个筛选"回调由屏幕自己组合（置值 + 立即
/// 重跑搜索），这里只管状态本身。
class SearchFilters {
  String language = 'all';
  String order = 'default';
  String extension = 'all';
  int? yearFrom;
  int? yearTo;

  /// General-search exact match (`e=1`); full-text has its own
  /// [fullTextExact].
  bool generalExact = false;

  /// Category scope (general mode only): the picked category's id and
  /// localized display name. Set from the filter dialog, the category
  /// picker, or the constructor (detail-page chips). Null means the
  /// search is unscoped. Cleared on mode switch — a category belongs
  /// to the general search the way its sort default does.
  int? categoryId;
  String? categoryName;

  /// Content-type filter inside a category (`book` / `article`);
  /// null means any content type. Only meaningful while a category
  /// is picked — clearing the category clears this too.
  String? contentType;

  /// Full-text-only extras (words/phrase match + exact flag); their
  /// default is `words` / off (the site's working default,
  /// device-proven 2026-11-11).
  String fullTextMatchType = 'words';
  bool fullTextExact = false;

  /// The exact-match flag for [mode]: full-text keeps its own flag
  /// (the two endpoints have separate semantics).
  bool exactFor(SearchMode mode) =>
      mode == SearchMode.fulltext ? fullTextExact : generalExact;

  int activeFilterCount(SearchMode mode) {
    switch (mode) {
      case SearchMode.fulltext:
        // The full-text request DOES carry language / extension
        // (`/fulltext/?…&languages[]=…&extensions[]=…`, verified
        // end-to-end: search_screen → FullTextSearchParams →
        // ZLibraryFullText.searchFullText), and the page shows both
        // sections in this mode — so the badge counts them, same as
        // the general branch. Only article mode hides those filters.
        return (language != 'all' ? 1 : 0) +
            (order != 'popular' ? 1 : 0) +
            (extension != 'all' ? 1 : 0) +
            (fullTextMatchType != 'words' ? 1 : 0) +
            (fullTextExact ? 1 : 0) +
            (yearFrom != null ? 1 : 0) +
            (yearTo != null ? 1 : 0);
      case SearchMode.article:
        // Article search sends only the query and sort (v1) — the
        // page hides the language / extension sections so the UI
        // never promises a filter the request does not carry.
        return order != 'default' ? 1 : 0;
      case SearchMode.general:
        return (language != 'all' ? 1 : 0) +
            (order != 'default' ? 1 : 0) +
            (extension != 'all' ? 1 : 0) +
            (yearFrom != null ? 1 : 0) +
            (yearTo != null ? 1 : 0) +
            (generalExact ? 1 : 0) +
            (categoryId != null ? 1 : 0) +
            (contentType != null ? 1 : 0);
    }
  }

  /// 筛选对话框"使用"回填（取消返回 null，不进这里）。exact 与
  /// matchType 按模式各归各位。
  void applyFrom(SearchFilterResult result, {required SearchMode mode}) {
    language = result.language;
    order = result.order;
    extension = result.extension;
    yearFrom = result.yearFrom;
    yearTo = result.yearTo;
    if (mode == SearchMode.fulltext) {
      fullTextExact = result.exact;
      fullTextMatchType = result.matchType;
    } else {
      generalExact = result.exact;
    }
    categoryId = result.categoryId;
    categoryName = result.categoryName;
    contentType = result.contentType;
  }
}
