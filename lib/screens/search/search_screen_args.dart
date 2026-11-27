/// Arguments for opening the search screen (P1-4 split of
/// search_screen.dart): moved out verbatim. Re-exported from
/// search_screen.dart so existing call sites keep importing it
/// unchanged.
library;

import '../../constants/search_filters.dart';

/// Arguments for opening the search screen with a preset: either
/// scoped to one category (browse it immediately, empty query) or
/// pre-filled with a query (run it immediately). The category pages
/// are gone — category lives only inside search now, so the category
/// form is also what the book-detail category chips navigate to;
/// the query form is what the book-detail author/publisher taps
/// navigate to.
class SearchScreenArgs {
  final int? categoryId;
  final String? categoryName;

  /// Query to pre-fill and run on open (detail-page author/publisher
  /// tap). Null means no preset query.
  final String? query;

  /// Field the query is scoped to when it comes from a detail-page
  /// author/publisher tap (`author` / `publisher`); null is an
  /// unscoped general search. See [SearchField].
  final SearchField? field;

  const SearchScreenArgs({
    this.categoryId,
    this.categoryName,
    this.query,
    this.field,
  });
}
