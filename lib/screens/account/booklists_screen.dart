import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/booklist_detail_provider.dart';
import '../../providers/booklists_provider.dart';
import '../../providers/zlibrary_provider.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_metrics.dart';
import '../../widgets/booklist_card.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/loading_widget.dart';
import '../../widgets/confirm_dialog.dart';
import 'widgets/booklist_color_dialog.dart';
import 'widgets/create_booklist_dialog.dart';

import '../../utils/app_snack.dart';

/// Booklists: the signed-in user's own booklists and public booklists to
/// discover, with search on both; sort and list/grid view live on
/// discover only — my own lists need neither, and always render as a
/// grid. Tapping a list opens its books. The "my booklists" tab can create a new list
/// (`createBooklist`), edit one, change its color, flip it
/// public/private, favorite it and delete one; adding a book to a list
/// lives on the book detail page (`addBookToBooklist`) and removing a
/// book from a list lives on the detail screen
/// (`BooklistDetailController.removeBook`).
///
/// Loading, paging, cache and the WebView fallback live in
/// [BooklistsController]; this widget only renders its state. The
/// discover list/grid choice is per-screen state (like the search
/// screen's view toggle), not persisted.
class BooklistsScreen extends ConsumerStatefulWidget {
  const BooklistsScreen({super.key});

  @override
  ConsumerState<BooklistsScreen> createState() => _BooklistsScreenState();
}

class _BooklistsScreenState extends ConsumerState<BooklistsScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  bool _isGridView = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 300) {
      ref.read(booklistsControllerProvider.notifier).loadMore();
    }
  }

  void _clearSearch() {
    _searchController.clear();
    ref.read(booklistsControllerProvider.notifier).search('');
  }

  /// Ask for a name (and optional description, color, private flag),
  /// create the list on the account, then show it at the top of "my
  /// booklists" without a reload (or refresh in the background when
  /// the answer carried no list).
  Future<void> _createBooklist() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showDialog<
        ({
          String title,
          String description,
          int color,
          bool isPrivate,
        })>(
      context: context,
      builder: (context) => const CreateBooklistDialog(),
    );
    if (result == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(booklistsControllerProvider.notifier);
    final response = await ref.read(zlibraryApiProvider).createBooklist(
          title: result.title,
          description: result.description,
          color: result.color,
          isPrivate: result.isPrivate,
        );
    if (!mounted) return;
    if (response.success) {
      showAppSnackOn(messenger, l10n.booklistCreated);
      // The answer usually carries the created list: put it at the top
      // of the mine page instead of reloading the whole page. When the
      // answer is an empty body (no list to insert), refresh the mine
      // page in the background instead of blocking on it.
      final created = response.data;
      if (created != null) {
        controller.noteBooklistCreated(created);
      } else if (ref.read(booklistsControllerProvider).tab ==
          BooklistTab.mine) {
        controller.refreshMineAfterCreate();
      }
    } else {
      showAppSnackOn(
        messenger,
        l10n.booklistCreateFailed(response.error ?? ''),
      );
    }
  }

  /// Edit one of the user's own lists: prefill the create dialog,
  /// then update the entry in place (or reload when the answer
  /// carried no updated list).
  Future<void> _editBooklist(Booklist list) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showDialog<
        ({
          String title,
          String description,
          int color,
          bool isPrivate,
        })>(
      context: context,
      builder: (context) => CreateBooklistDialog(
        isEdit: true,
        initialTitle: list.name,
        initialDescription: list.description,
        initialColor: list.color,
        initialPrivate: list.isPrivate,
      ),
    );
    if (result == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(booklistsControllerProvider.notifier);
    final response = await controller.editBooklist(
      list,
      title: result.title,
      description: result.description,
      isPrivate: result.isPrivate,
      color: result.color,
    );
    if (!mounted) return;
    if (response.success) {
      showAppSnackOn(messenger, l10n.booklistEdited);
      if (response.data == null) {
        await controller.loadFirst();
      }
    } else {
      showAppSnackOn(
        messenger,
        l10n.booklistEditFailed(response.error ?? ''),
      );
    }
  }

  /// Change one of the user's own lists' color via the color dialog.
  Future<void> _changeBooklistColor(Booklist list) async {
    final l10n = AppLocalizations.of(context)!;
    final color = await showDialog<int>(
      context: context,
      builder: (context) =>
          BooklistColorDialog(currentColor: list.color ?? 0),
    );
    if (color == null || color == list.color || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(booklistsControllerProvider.notifier);
    final response = await controller.setBooklistColor(list, color);
    if (!mounted) return;
    showAppSnackOn(
      messenger,
      response.success
          ? l10n.booklistColorChanged
          : l10n.booklistColorFailed(response.error ?? ''),
    );
  }

  /// Flip one of the user's own lists between public and private.
  Future<void> _toggleBooklistPublic(Booklist list) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(booklistsControllerProvider.notifier);
    final response = await controller.toggleBooklistPublic(list);
    if (!mounted) return;
    showAppSnackOn(
      messenger,
      response.success
          ? (list.isPrivate
              ? l10n.booklistMadePublic
              : l10n.booklistMadePrivate)
          : l10n.booklistVisibilityFailed(response.error ?? ''),
    );
  }

  /// Favorite or unfavorite a booklist (either tab).
  Future<void> _toggleBooklistFavorite(Booklist list) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(booklistsControllerProvider.notifier);
    final favorite = !list.isFavorite;
    final response =
        await controller.setBooklistFavorite(list, favorite);
    if (!mounted) return;
    showAppSnackOn(
      messenger,
      response.success
          ? (favorite ? l10n.booklistFavorited : l10n.booklistUnfavorited)
          : l10n.booklistFavoriteFailed(response.error ?? ''),
    );
  }

  /// Share a booklist's name + URL through the system share sheet.
  Future<void> _shareBooklist(Booklist list) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await SharePlus.instance.share(
        ShareParams(text: '${list.name}\n${list.url}'),
      );
    } catch (_) {
      if (!mounted) return;
      showAppSnack(context, l10n.shareFailed);
    }
  }

  /// One menu action from a card's "…" menu.
  Future<void> _onMenuSelected(
    Booklist list,
    BooklistMenuAction action,
  ) async {
    switch (action) {
      case BooklistMenuAction.edit:
        await _editBooklist(list);
      case BooklistMenuAction.changeColor:
        await _changeBooklistColor(list);
      case BooklistMenuAction.togglePublic:
        await _toggleBooklistPublic(list);
      case BooklistMenuAction.toggleFavorite:
        await _toggleBooklistFavorite(list);
      case BooklistMenuAction.share:
        await _shareBooklist(list);
      case BooklistMenuAction.delete:
        await _confirmDelete(list);
    }
  }

  /// Delete one of the user's own lists: confirm first (destructive),
  /// then the controller's optimistic removal; on failure the list is
  /// restored and the error is shown, on success nothing more is
  /// needed — the controller already removed it and invalidated the
  /// cached page.
  Future<void> _confirmDelete(Booklist list) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.booklistDeleteConfirm,
      message: l10n.booklistDeleteDesc,
      confirmLabel: l10n.delete,
      cancelLabel: l10n.cancel,
    );
    if (!confirmed || !mounted) return;
    unawaited(HapticFeedback.mediumImpact());
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(booklistsControllerProvider.notifier);
    final response = await controller.deleteBooklist(list);
    if (!mounted) return;
    if (response.success) {
      showAppSnackOn(messenger, l10n.booklistDeleted);
    } else {
      showAppSnackOn(
        messenger,
        l10n.booklistDeleteFailed(response.error ?? ''),
      );
    }
  }

  /// Pick a sort order via the single-choice dialog (same idiom as the
  /// domain selector: selected row = filled check in primary + bold
  /// primary title, tap applies + closes).
  Future<void> _pickSortOrder(String currentOrder) async {
    final order = await showDialog<String>(
      context: context,
      builder: (context) => _BooklistSortDialog(currentOrder: currentOrder),
    );
    if (order == null || order == currentOrder) return;
    ref.read(booklistsControllerProvider.notifier).setOrder(order);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(booklistsControllerProvider);
    final recommended = ref.watch(recommendedBooklistsProvider);
    final controller = ref.read(booklistsControllerProvider.notifier);
    final showFab =
        state.tab == BooklistTab.mine && state.phase != BooklistsPhase.loggedOut;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          state.tab == BooklistTab.mine
              ? l10n.booklists
              : l10n.discoverBooklists,
        ),
        actions: [
          IconButton(
            tooltip: state.tab == BooklistTab.mine
                ? l10n.discoverBooklists
                : l10n.myBooklists,
            icon: Icon(
              state.tab == BooklistTab.mine
                  ? Icons.explore_outlined
                  : Icons.person_outline_rounded,
            ),
            onPressed: () => controller.setTab(
              state.tab == BooklistTab.mine
                  ? BooklistTab.discover
                  : BooklistTab.mine,
            ),
          ),
        ],
      ),
      floatingActionButton: showFab
          ? FloatingActionButton.extended(
              onPressed: _createBooklist,
              icon: const Icon(Icons.add_rounded),
              label: Text(l10n.createBooklist),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: controller.refresh,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _header(l10n, state, controller)),
            ..._body(l10n, state, controller, recommended),
          ],
        ),
      ),
    );
  }

  Widget _header(
    AppLocalizations l10n,
    BooklistsState state,
    BooklistsController controller,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        children: [
          _searchBar(l10n, controller),
          // Sort + view toggle live on discover only: my own lists
          // need neither, and always render as a grid (see _body).
          if (state.tab == BooklistTab.discover) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => _pickSortOrder(state.order),
                  icon: const Icon(Icons.swap_vert_rounded, size: 18),
                  label: Text(_sortLabel(l10n, state.order)),
                ),
                const Spacer(),
                IconButton(
                  tooltip: _isGridView ? l10n.listView : l10n.gridView,
                  icon: Icon(
                    _isGridView
                        ? Icons.view_list_rounded
                        : Icons.grid_view_rounded,
                  ),
                  onPressed: () => setState(() => _isGridView = !_isGridView),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// The current sort order's label for the sort button.
  String _sortLabel(AppLocalizations l10n, String order) {
    return switch (order) {
      'date_created' => l10n.booklistSortNewest,
      'date_updated' => l10n.booklistSortUpdated,
      _ => l10n.booklistSortPopular,
    };
  }

  // Capsule search field + soft shadow, matching the library page.
  Widget _searchBar(AppLocalizations l10n, BooklistsController controller) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        boxShadow: AppShadows.elevated(Theme.of(context).brightness),
      ),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _searchController,
        builder: (context, value, _) => TextField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          onSubmitted: controller.search,
          decoration: InputDecoration(
            hintText: l10n.searchBooklists,
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
          ),
        ),
      ),
    );
  }

  List<Widget> _body(
    AppLocalizations l10n,
    BooklistsState state,
    BooklistsController controller,
    RecommendedBooklistsState recommended,
  ) {
    switch (state.phase) {
      case BooklistsPhase.loading:
        return const [SliverToBoxAdapter(child: BooklistSkeletonList())];
      case BooklistsPhase.loggedOut:
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.login_rounded,
              title: l10n.loginToViewBooklists,
              action: FilledButton(
                onPressed: () => AppRoutes.openLogin(context),
                child: Text(l10n.login),
              ),
            ),
          ),
        ];
      case BooklistsPhase.error:
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.error_outline,
              title: l10n.error,
              message: state.error,
              action: FilledButton(
                onPressed: controller.loadFirst,
                child: Text(l10n.retry),
              ),
            ),
          ),
        ];
      case BooklistsPhase.ready:
        if (state.lists.isEmpty) {
          return [
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.collections_bookmark_outlined,
                title: l10n.noBooklists,
              ),
            ),
          ];
        }
        return [
          if (state.tab == BooklistTab.discover &&
              recommended.lists.isNotEmpty)
            SliverToBoxAdapter(
              child: _RecommendedSection(
                l10n: l10n,
                lists: recommended.lists,
              ),
            ),
          // My own lists always render as a grid (no sort or view
          // controls on that tab); discover follows the toggle.
          if (state.tab == BooklistTab.mine || _isGridView)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              sliver: SliverGrid.builder(
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 0.82,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                ),
                itemCount: state.lists.length,
                itemBuilder: (context, index) {
                  final list = state.lists[index];
                  return BooklistGridCard(
                    list: list,
                    isMine: state.tab == BooklistTab.mine,
                    onTap: () => AppRoutes.openBooklistDetail(
                      context,
                      BooklistDetailArgs(
                        booklist: list,
                        canEdit: state.tab == BooklistTab.mine,
                      ),
                    ),
                    onLongPress: state.tab == BooklistTab.mine
                        ? () => _confirmDelete(list)
                        : null,
                    onMenuSelected: (action) =>
                        _onMenuSelected(list, action),
                  );
                },
              ),
            )
          else
            SliverList.builder(
              itemCount: state.lists.length,
              itemBuilder: (context, index) {
                final list = state.lists[index];
                return BooklistCard(
                  list: list,
                  isMine: state.tab == BooklistTab.mine,
                  onTap: () => AppRoutes.openBooklistDetail(
                    context,
                    BooklistDetailArgs(
                      booklist: list,
                      canEdit: state.tab == BooklistTab.mine,
                    ),
                  ),
                  onLongPress: state.tab == BooklistTab.mine
                      ? () => _confirmDelete(list)
                      : null,
                  onMenuSelected: (action) => _onMenuSelected(list, action),
                );
              },
            ),
          if (state.isLoadingMore)
            const SliverToBoxAdapter(child: LoadingWidget.more()),
          // Room for the floating action button.
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ];
    }
  }
}

/// Recommended booklists above the discover list: a section header and
/// a horizontal row of grid tiles.
class _RecommendedSection extends StatelessWidget {
  final AppLocalizations l10n;
  final List<Booklist> lists;

  const _RecommendedSection({required this.l10n, required this.lists});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            l10n.recommendedBooklists,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          height: 236,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            itemCount: lists.length,
            itemBuilder: (context, index) {
              final list = lists[index];
              return SizedBox(
                width: 168,
                child: BooklistGridCard(
                  list: list,
                  onTap: () => AppRoutes.openBooklistDetail(
                    context,
                    BooklistDetailArgs(booklist: list),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Single-choice sort dialog, same idiom as the domain selector:
/// selected row = filled check in primary + bold primary title, tap
/// applies + closes. Pops the picked `order` value, or null when
/// cancelled.
class _BooklistSortDialog extends StatelessWidget {
  final String currentOrder;

  const _BooklistSortDialog({required this.currentOrder});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final options = <(String, String)>[
      ('popular', l10n.booklistSortPopular),
      ('date_created', l10n.booklistSortNewest),
      ('date_updated', l10n.booklistSortUpdated),
    ];
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      title: Text(
        l10n.booklistSort,
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
