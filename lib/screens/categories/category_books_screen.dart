import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants/search_filters.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../models/display_book.dart';
import '../../providers/category_books_provider.dart';
import '../../routes/app_routes.dart';
import '../../widgets/book_list_tile.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/gradient_app_bar.dart';
import '../../widgets/loading_widget.dart';
import '../search/widgets/search_filter_page.dart';

// Existing callers (routes) import the args class from this screen's
// library.
export '../../providers/category_books_provider.dart'
    show CategoryBooksArgs;

/// Books in one category: the category name as the title above the
/// book list, an in-category search box, a sort button and a filter
/// button. Loading, paging and the WebView fallback live in
/// [CategoryBooksController]; tapping a book opens its detail page
/// (the books carry their hash, so the detail loads fully). A
/// removed book (copyright / deleted) stays tappable but greyed out,
/// and its download button is blocked on the detail page via
/// [BookDetailArgs.unavailableReason] — the full-text hit tile's
/// pattern.
class CategoryBooksScreen extends ConsumerStatefulWidget {
  final CategoryBooksArgs args;

  const CategoryBooksScreen({super.key, required this.args});

  @override
  ConsumerState<CategoryBooksScreen> createState() =>
      _CategoryBooksScreenState();
}

class _CategoryBooksScreenState extends ConsumerState<CategoryBooksScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  late final _provider = categoryBooksControllerProvider(widget.args);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 300) {
      ref.read(_provider.notifier).loadMore();
    }
  }

  void _clearSearch() {
    _searchController.clear();
    ref.read(_provider.notifier).search('');
  }

  /// Sort dialog (the domain-selector idiom): one dense row per
  /// sort value, the current one marked with a primary
  /// `check_circle`.
  Future<void> _pickSortOrder(String currentOrder) async {
    final order = await showDialog<String>(
      context: context,
      builder: (context) => _CategorySortDialog(currentOrder: currentOrder),
    );
    if (order == null || order == currentOrder) return;
    ref.read(_provider.notifier).setOrder(order);
  }

  /// Filter page (the search screen's full-screen filter page,
  /// reused): exact-match switch plus year / language / extension
  /// dropdowns. Sort stays in its own dialog ([_pickSortOrder]);
  /// content type is not shown (its option values are unverified —
  /// see [SearchFilterPage]). Staged editing: 使用 applies, ✕
  /// discards, 删除筛选 resets the staged values. On apply, an
  /// all-defaults result goes through
  /// [CategoryBooksController.resetFilters] (one reload); otherwise
  /// the five setters run (each a no-op when its value is
  /// unchanged).
  Future<void> _openFilterPage() async {
    final locale = Localizations.localeOf(context).languageCode;
    final state = ref.read(_provider);
    final controller = ref.read(_provider.notifier);
    final result = await Navigator.of(context).push<SearchFilterResult>(
      MaterialPageRoute<SearchFilterResult>(
        builder: (context) => SearchFilterPage(
          language: state.language,
          order: state.order,
          extension: state.extension,
          yearFrom: state.yearFrom,
          yearTo: state.yearTo,
          exact: state.exact,
          matchType: 'words',
          languageNames: getLanguageDisplayNames(locale),
          orderNames: const <String, String>{},
          extensionNames: getExtensionDisplayNames(locale),
          defaultOrder: 'popular',
          showExact: true,
          showMatchType: false,
          showYears: true,
          showLanguage: true,
          showSort: false,
          showExtension: true,
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (result.language == 'all' &&
        result.extension == 'all' &&
        !result.exact &&
        result.yearFrom == null &&
        result.yearTo == null) {
      controller.resetFilters();
      return;
    }
    controller.setLanguage(result.language);
    controller.setExtension(result.extension);
    controller.setExact(result.exact);
    controller.setYearFrom(result.yearFrom);
    controller.setYearTo(result.yearTo);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(_provider);
    final controller = ref.read(_provider.notifier);

    return Scaffold(
      appBar: GradientAppBar(title: widget.args.categoryName),
      body: RefreshIndicator(
        onRefresh: controller.loadFirst,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _header(l10n, state, controller)),
            ..._body(l10n, state),
          ],
        ),
      ),
    );
  }

  Widget _header(
    AppLocalizations l10n,
    CategoryBooksState state,
    CategoryBooksController controller,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        children: [
          _searchBar(l10n, controller),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => _pickSortOrder(state.order),
                icon: const Icon(Icons.swap_vert_rounded, size: 18),
                label: Text(_sortLabel(state.order)),
              ),
              const Spacer(),
              IconButton(
                tooltip: l10n.filter,
                icon: const Icon(Icons.tune_rounded),
                onPressed: _openFilterPage,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The current sort order's label for the sort button.
  String _sortLabel(String order) {
    final locale = Localizations.localeOf(context).languageCode;
    return getCategoryOrderDisplayNames(locale)[order] ?? order;
  }

  // Capsule search field + soft shadow, matching the booklists page.
  Widget _searchBar(
    AppLocalizations l10n,
    CategoryBooksController controller,
  ) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.2 : 0.06),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _searchController,
        builder: (context, value, _) => TextField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          onSubmitted: controller.search,
          decoration: InputDecoration(
            hintText: l10n.categorySearchHint,
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    tooltip: l10n.clear,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: _clearSearch,
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
    );
  }

  List<Widget> _body(AppLocalizations l10n, CategoryBooksState state) {
    if (state.isLoading) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 48),
            child: LoadingWidget(message: l10n.loading),
          ),
        ),
      ];
    }
    if (state.error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.error_outline,
            title: l10n.error,
            message: state.error,
            action: FilledButton(
              onPressed: () => ref.read(_provider.notifier).loadFirst(),
              child: Text(l10n.retry),
            ),
          ),
        ),
      ];
    }
    if (state.books.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.category_outlined,
            title: l10n.noCategoryBooks,
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        sliver: SliverList.builder(
          itemCount: state.books.length,
          itemBuilder: (context, index) {
            final categoryBook = state.books[index];
            final book = categoryBook.book;
            final display = book.toDisplay();
            final cs = Theme.of(context).colorScheme;
            final tile = BookListTile(
              book: display,
              showCover: true,
              trailing: categoryBook.isFavorite
                  ? Icon(
                      Icons.favorite_rounded,
                      size: 18,
                      color: cs.primary,
                    )
                  : null,
              onTap: () => AppRoutes.openBookDetailForDisplayBook(
                context,
                display,
                unavailableReason: categoryBook.unavailableReason,
              ),
            );
            if (!categoryBook.removed) return tile;
            // Removed (copyright / deleted): greyed out like a
            // full-text hit, still tappable; the detail page blocks
            // the download button via `unavailableReason`.
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Opacity(opacity: 0.55, child: tile),
                Padding(
                  // Aligned with the tile's text column: 16
                  // (content padding) + 48 (cover) + 16 (title gap).
                  padding: const EdgeInsets.only(left: 80, bottom: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      categoryBook.unavailableReason == 'copyright'
                          ? l10n.copyrightRemoved
                          : l10n.removedBook,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      if (state.isLoadingMore)
        const SliverToBoxAdapter(child: LoadingWidget.more()),
    ];
  }
}

/// Sort dialog for the category books screen (the domain-selector
/// idiom, same shape as the booklists sort dialog).
class _CategorySortDialog extends StatelessWidget {
  final String currentOrder;

  const _CategorySortDialog({required this.currentOrder});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final locale = Localizations.localeOf(context).languageCode;
    final names = getCategoryOrderDisplayNames(locale);
    final options = <(String, String)>[
      for (final order in categorySearchOrders.keys)
        (order, names[order] ?? order),
    ];
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      title: Text(
        l10n.sort,
        style: const TextStyle(fontSize: 18),
      ),
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
