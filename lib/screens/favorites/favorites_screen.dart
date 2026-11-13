import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:open_filex/open_filex.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../models/unified_shelf_item.dart';
import '../../providers/books_provider.dart';
import '../../providers/download_provider.dart';
import '../../providers/shelf_categories_provider.dart';
import '../../providers/shelf_provider.dart';
import '../../routes/app_routes.dart';
import '../../screens/search/search_screen.dart';
import '../../services/media_store.dart';
import '../../theme/app_metrics.dart';
import '../../widgets/empty_state.dart';
import 'category_actions.dart';
import 'widgets/shelf_book_sliver.dart';
import 'widgets/shelf_chip.dart';
import '../../widgets/loading_widget.dart';

import '../../utils/app_snack.dart';
import '../../utils/error_text.dart';
enum _ShelfSort { defaultOrder, title, author }

class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

/// Orchestrator only: watches the shelf / categories providers, owns
/// the select mode, the filters and the action wiring, and delegates
/// the category dialogs to [ShelfCategoryActions] and the list /
/// grid body to [ShelfBookSliver].
class _FavoritesScreenState extends ConsumerState<FavoritesScreen>
    implements ShelfCategoryHost {
  final _searchController = TextEditingController();
  bool _isListView = false;
  bool _isSelectMode = false;
  final Set<int> _selectedBookIds = {};
  String? _selectedCategoryId;
  _ShelfSort _sort = _ShelfSort.defaultOrder;

  /// The category flows (create / rename / delete / assign / manage),
  /// extracted to category_actions.dart.
  late final ShelfCategoryActions _actions = ShelfCategoryActions(this);

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final shelf = ref.watch(unifiedShelfProvider);
    final library = ref.watch(savedBooksProvider);
    final categories = ref.watch(shelfCategoriesProvider);
    final hasSourceError = _sourceError(library);

    final allItems = shelf.valueOrNull ?? <UnifiedShelfItem>[];
    final visible = _filteredItems(allItems, categories);
    // Index built once per build so every item is an O(1) lookup
    // instead of a linear scan over all categories. Download state is
    // deliberately not read here: each tile watches
    // downloadTaskProvider for its own book id, so one progress tick
    // rebuilds only that tile instead of the whole shelf.
    final categoryNameById = <String, String>{
      for (final category in categories.categories)
        category.id: category.name,
    };
    // Only the select-mode app bar needs the visible library ids.
    final selectedVisible = _isSelectMode
        ? visible
              .where((item) => item.source == ShelfSource.library)
              .map((item) => int.tryParse(item.rawBookId))
              .whereType<int>()
              .toSet()
        : const <int>{};

    return Scaffold(
      body: shelf is AsyncLoading && allItems.isEmpty
          ? LoadingWidget.page(message: l.loadingFavorites)
          : RefreshIndicator(
              onRefresh: () async {
                await ref
                    .read(savedBooksProvider.notifier)
                    .loadSavedBooks();
              },
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  _appBar(l, selectedVisible),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: Column(
                        children: [
                          if (!_isSelectMode) _searchBar(l),
                          _categoryBar(l, allItems, categories),
                          _sortBar(l, visible.length),
                          if (hasSourceError) _errorBanner(l),
                        ],
                      ),
                    ),
                  ),
                  if (visible.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _emptyState(l, hasSourceError),
                    )
                  else ...[
                    ShelfBookSliver(
                      items: visible,
                      categories: categories,
                      categoryNameById: categoryNameById,
                      isListView: _isListView,
                      isSelectMode: _isSelectMode,
                      selectedBookIds: _selectedBookIds,
                      onItemTap: _onItemTap,
                      onItemLongPress: _onItemLongPress,
                    ),
                    const SliverPadding(padding: EdgeInsets.only(bottom: 28)),
                  ],
                ],
              ),
            ),
      bottomNavigationBar: _isSelectMode && _selectedBookIds.isNotEmpty
          ? _bottomBar(l, visible)
          : null,
    );
  }

  List<UnifiedShelfItem> _filteredItems(
    List<UnifiedShelfItem> all,
    ShelfCategoriesState categories,
  ) {
    final query = _searchController.text.trim().toLowerCase();
    final result = all.where((item) {
      final assigned = categories.categoryFor(item);
      if (_selectedCategoryId == kShelfUncategorizedId && assigned != null) {
        return false;
      }
      if (_selectedCategoryId != null &&
          _selectedCategoryId != kShelfUncategorizedId &&
          assigned != _selectedCategoryId) {
        return false;
      }
      if (query.isEmpty) return true;
      return item.displayBook.title.toLowerCase().contains(query) ||
          (item.displayBook.author?.toLowerCase().contains(query) ?? false);
    }).toList();
    if (_sort != _ShelfSort.defaultOrder) {
      result.sort((a, b) {
        final left = _sort == _ShelfSort.title
            ? a.displayBook.title
            : a.displayBook.author ?? '';
        final right = _sort == _ShelfSort.title
            ? b.displayBook.title
            : b.displayBook.author ?? '';
        return left.toLowerCase().compareTo(right.toLowerCase());
      });
    }
    return result;
  }

  bool _sourceError(AsyncValue<dynamic> library) {
    return library.hasError;
  }

  Widget _appBar(AppLocalizations l, Set<int> visibleIds) {
    if (_isSelectMode) {
      return SliverAppBar(
        pinned: true,
        leading: IconButton(
          tooltip: l.cancel,
          icon: const Icon(Icons.close),
          onPressed: _exitSelectMode,
        ),
        title: Text('${_selectedBookIds.length} ${l.shelfSelected}'),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              if (visibleIds.isNotEmpty &&
                  _selectedBookIds.containsAll(visibleIds)) {
                _selectedBookIds.removeAll(visibleIds);
              } else {
                _selectedBookIds.addAll(visibleIds);
              }
            }),
            child: Text(l.selectAll),
          ),
        ],
      );
    }
    return SliverAppBar(
      pinned: true,
      floating: true,
      title: Text(l.shelfTitle),
      actions: [
        IconButton(
          tooltip: l.shelfManageCategories,
          icon: const Icon(Icons.label_outline_rounded),
          onPressed: _actions.manageCategories,
        ),
        IconButton(
          tooltip: _isListView
              ? l.shelfView
              : l.listView,
          onPressed: () => setState(() => _isListView = !_isListView),
          icon: Icon(
            _isListView ? Icons.grid_view_rounded : Icons.view_list_rounded,
          ),
        ),
      ],
    );
  }

  // 与首页搜索框一致：胶囊形 + 柔和投影，填充色/圆角沿用全局 inputDecorationTheme。
  Widget _searchBar(AppLocalizations l) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        boxShadow: AppShadows.elevated(Theme.of(context).brightness),
      ),
      child: TextField(
        controller: _searchController,
        onChanged: (_) {
          _exitSelectMode();
          setState(() {});
        },
        decoration: InputDecoration(
          hintText: l.shelfSearchHint,
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  tooltip: l.clear,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () {
                    _searchController.clear();
                    setState(() {});
                  },
                ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 14,
          ),
        ),
      ),
    ),
  );

  Widget _categoryBar(
    AppLocalizations l,
    List<UnifiedShelfItem> all,
    ShelfCategoriesState state,
  ) {
    final scoped = all;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        children: [
          _categoryChip(l.shelfAllCategories, null, scoped.length),
          _categoryChip(
            l.shelfUncategorized,
            kShelfUncategorizedId,
            scoped.where((item) => state.categoryFor(item) == null).length,
          ),
          for (final category in state.categories)
            _categoryChip(
              category.name,
              category.id,
              state.countFor(category.id, scoped),
            ),
          IconButton(
            tooltip: l.shelfNewCategory,
            visualDensity: VisualDensity.compact,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            onPressed: _actions.createCategory,
            icon: const Icon(Icons.add_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _categoryChip(String name, String? id, int count) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: Center(
      child: ShelfChip(
        label: '$name $count',
        selected: _selectedCategoryId == id,
        dense: true,
        onSelected: () {
          _exitSelectMode();
          setState(() => _selectedCategoryId = id);
        },
      ),
    ),
  );

  Widget _sortBar(AppLocalizations l, int count) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 0, 0, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            '${l.shelfCount(count)} · ${l.shelfLongPressHint}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        PopupMenuButton<_ShelfSort>(
          tooltip: l.shelfSort,
          onSelected: (value) => setState(() => _sort = value),
          itemBuilder: (_) => [
            PopupMenuItem(
              value: _ShelfSort.defaultOrder,
              child: Text(l.shelfSortDefault),
            ),
            PopupMenuItem(
              value: _ShelfSort.title,
              child: Text(l.shelfSortTitle),
            ),
            PopupMenuItem(
              value: _ShelfSort.author,
              child: Text(l.shelfSortAuthor),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Row(
              children: [
                Icon(
                  Icons.swap_vert_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 3),
                Text(
                  l.shelfSort,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _errorBanner(AppLocalizations l) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Card(
      child: ListTile(
        leading: const Icon(Icons.wifi_off_rounded),
        title: Text(l.shelfSourceLoadFailed),
        trailing: TextButton(
          onPressed: () {
            ref.read(savedBooksProvider.notifier).loadSavedBooks();
          },
          child: Text(l.retry),
        ),
      ),
    ),
  );

  Widget _emptyState(AppLocalizations l, bool hasSourceError) {
    final searched = _searchController.text.trim().isNotEmpty;
    final filtered = searched || _selectedCategoryId != null;
    final title = hasSourceError
        ? l.shelfSourceLoadFailed
        : filtered
        ? l.shelfNoMatches
        : l.shelfEmpty;
    final message = hasSourceError
        ? l.shelfRetryHint
        : filtered
        ? l.shelfTryOtherFilter
        : l.shelfEmptyMessage;
    return EmptyState(
      icon: filtered ? Icons.search_off_rounded : Icons.auto_stories_outlined,
      title: title,
      message: message,
      action: FilledButton.tonal(
        onPressed: hasSourceError
            ? () {
                ref.read(savedBooksProvider.notifier).loadSavedBooks();
              }
            : filtered
            ? () => setState(() {
                _searchController.clear();
                _selectedCategoryId = null;
              })
            : () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SearchScreen(),
                ),
              ),
        child: Text(
          hasSourceError
              ? l.retry
              : filtered
              ? l.shelfClearFilters
              : l.shelfFindBooks,
        ),
      ),
    );
  }

  Widget _bottomBar(AppLocalizations l, List<UnifiedShelfItem> visible) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                _selectionAction(
                  icon: Icons.label_outline_rounded,
                  label: l.shelfAddToCategory,
                  onPressed: () => _actions.showCategoryPicker(
                    visible
                        .where(
                          (item) =>
                              item.source == ShelfSource.library &&
                              _selectedBookIds.contains(
                                int.tryParse(item.rawBookId),
                              ),
                        )
                        .toList(),
                  ),
                ),
                _selectionAction(
                  icon: Icons.delete_outline_rounded,
                  label: l.batchRemove,
                  onPressed: () => _confirmBatchRemove(l),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _selectionAction({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) => Expanded(
    child: TextButton(
      onPressed: onPressed,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 21),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
  );

  int? _libraryId(UnifiedShelfItem item) =>
      item.source == ShelfSource.library ? int.tryParse(item.rawBookId) : null;

  void _onItemTap(UnifiedShelfItem item) {
    final id = _libraryId(item);
    if (_isSelectMode && id != null) {
      _toggleSelect(id);
      return;
    }
    final book = item.displayBook.original;
    if (book is Book) {
      AppRoutes.openBookDetailForBook(context, book);
    }
  }

  /// Long-press on a shelf row: library items enter select mode;
  /// non-library items (no library id) open the single-book sheet.
  void _onItemLongPress(UnifiedShelfItem item, DownloadTask? local) {
    final id = _libraryId(item);
    if (id == null) {
      _showSingleBookActions(item, local);
    } else {
      _enterSelectMode(id);
    }
  }

  Future<void> _quickAction(UnifiedShelfItem item, DownloadTask? local) async {
    if (local?.filePath != null) {
      try {
        // MediaStoreFiles.exists understands both plain paths and the
        // content:// URIs of MediaStore-published downloads; File.exists
        // returns false for a content URI and would wrongly report the
        // file as missing.
        if (!await MediaStoreFiles.exists(local!.filePath!)) {
          ref.read(downloadProvider.notifier).markMissingFile(local.id);
          if (mounted) {
            _message(AppLocalizations.of(context)!.downloadFileMissing);
          }
          return;
        }
        // MediaStore-published downloads live at a content:// URI, which
        // OpenFilex cannot open — those go through the platform channel.
        if (MediaStoreFiles.isContentUri(local.filePath!)) {
          final opened = await MediaStoreFiles.open(local.filePath!);
          if (!opened && mounted) {
            _message(AppLocalizations.of(context)!.openFileFailed);
          }
          return;
        }
        final result = await OpenFilex.open(local.filePath!);
        if (result.type == ResultType.done) return;
        if (mounted) _message(result.message);
      } catch (error) {
        if (mounted) {
              _message(
                friendlyErrorText(error, AppLocalizations.of(context)!),
              );
            }
      }
      return;
    }
    if (mounted) _onItemTap(item);
  }

  Future<void> _showSingleBookActions(
    UnifiedShelfItem item,
    DownloadTask? local,
  ) async {
    unawaited(HapticFeedback.mediumImpact());
    final l = AppLocalizations.of(context)!;
    ModalRoute<dynamic>? sheetRoute;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        sheetRoute = ModalRoute.of(sheetContext);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  item.displayBook.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.menu_book_rounded),
                title: Text(
                  local != null
                      ? l.openFile
                      : l.shelfViewDetails,
                ),
                onTap: () => Navigator.pop(sheetContext, 'quick'),
              ),
              ListTile(
                leading: const Icon(Icons.label_outline_rounded),
                title: Text(l.shelfAddToCategory),
                onTap: () => Navigator.pop(sheetContext, 'category'),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: Text(l.shelfViewDetails),
                onTap: () => Navigator.pop(sheetContext, 'detail'),
              ),
            ],
          ),
        );
      },
    );
    await sheetRoute?.completed;
    if (!mounted) return;
    if (action == 'quick') {
      await _quickAction(item, local);
    } else if (action == 'category') {
      await _actions.showCategoryPicker([item]);
    } else if (action == 'detail') {
      _onItemTap(item);
    }
  }

  void _confirmBatchRemove(AppLocalizations l) {
    final ids = _selectedBookIds.map((id) => id.toString()).toList();
    if (ids.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.confirmRemoveTitle),
        content: Text(
          l.confirmRemoveMsg(ids.length),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _batchRemove(ids);
            },
            // 危险操作按钮统一走主题 error 色（此前硬编码 Colors.red[400]，
            // 动态取色/深色模式下与全局错误色不一致）。
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: Text(l.remove),
          ),
        ],
      ),
    );
  }

  /// 批量取消收藏：逐本调用接口，全部处理完后只刷新一次收藏列表。
  Future<void> _batchRemove(List<String> ids) async {
    await ref.read(savedBooksProvider.notifier).unsaveBooks(ids);
    if (mounted) _exitSelectMode();
  }

  void _toggleSelect(int id) => setState(() {
    if (!_selectedBookIds.add(id)) _selectedBookIds.remove(id);
  });

  void _enterSelectMode(int id) {
    unawaited(HapticFeedback.mediumImpact());
    setState(() {
      _isSelectMode = true;
      _selectedBookIds.add(id);
    });
  }

  void _exitSelectMode() {
    if (!_isSelectMode && _selectedBookIds.isEmpty) return;
    setState(() {
      _isSelectMode = false;
      _selectedBookIds.clear();
    });
  }

  // ── ShelfCategoryHost: hooks for the extracted category flows ──

  @override
  AppLocalizations l10n() => AppLocalizations.of(context)!;

  @override
  void showMessage(String message) => _message(message);

  @override
  void onCategoryDeleted(String categoryId) {
    if (mounted && _selectedCategoryId == categoryId) {
      setState(() => _selectedCategoryId = null);
    }
  }

  void _message(String message) => showAppSnack(context, message);
}
