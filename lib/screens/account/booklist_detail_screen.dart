import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../models/display_book.dart';
import '../../providers/booklist_detail_provider.dart';
import '../../routes/app_routes.dart';
import '../../theme/app_metrics.dart';
import '../../widgets/book_list_tile.dart';
import '../../widgets/booklist_card.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/loading_widget.dart';
import '../../widgets/confirm_dialog.dart';

import '../../utils/app_snack.dart';
// Existing callers (main.dart routes, the profile page) import the args
// class from this screen's library.
export '../../providers/booklist_detail_provider.dart' show BooklistDetailArgs;

/// Books inside one booklist: a header (cover, name, creator, counts,
/// expandable description) above the book list. Loading, paging, cache
/// and the WebView fallback live in [BooklistDetailController]; tapping a
/// book opens its detail page (the books carry their hash, so the detail
/// loads fully).
class BooklistDetailScreen extends ConsumerStatefulWidget {
  final BooklistDetailArgs args;

  const BooklistDetailScreen({super.key, required this.args});

  @override
  ConsumerState<BooklistDetailScreen> createState() =>
      _BooklistDetailScreenState();
}

class _BooklistDetailScreenState extends ConsumerState<BooklistDetailScreen> {
  final ScrollController _scrollController = ScrollController();

  late final _provider = booklistDetailControllerProvider(widget.args);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 300) {
      ref.read(_provider.notifier).loadMore();
    }
  }

  /// Remove one book from this (own) list: confirm first, then the
  /// controller's optimistic removal; on failure the book is restored
  /// and the error is shown.
  Future<void> _confirmRemove(Book book) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.booklistRemoveBookConfirm,
      message: book.title,
      confirmLabel: l10n.remove,
      cancelLabel: l10n.cancel,
    );
    if (!confirmed || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final response = await ref.read(_provider.notifier).removeBook(book);
    if (!mounted) return;
    if (response.success) {
      showAppSnackOn(messenger, l10n.booklistBookRemoved);
    } else {
      showAppSnackOn(
        messenger,
        l10n.booklistRemoveBookFailed(response.error ?? ''),
      );
    }
  }

  /// Add or edit the per-book note on one of this (own) list's books.
  Future<void> _editNote(Book book) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: book.note ?? '');
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          book.note == null || book.note!.isEmpty
              ? l10n.booklistAddNote
              : l10n.booklistEditNote,
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          decoration: InputDecoration(
            labelText: l10n.booklistNote,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    controller.dispose();
    if (note == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final response =
        await ref.read(_provider.notifier).saveNote(book, note);
    if (!mounted) return;
    showAppSnackOn(
      messenger,
      response.success
          ? l10n.booklistNoteSaved
          : l10n.booklistNoteFailed(response.error ?? ''),
    );
  }

  /// One menu action from a book row's "…" menu (own lists only).
  Future<void> _onBookMenuSelected(
    Book book,
    _DetailBookMenuAction action,
  ) async {
    switch (action) {
      case _DetailBookMenuAction.editNote:
        await _editNote(book);
      case _DetailBookMenuAction.remove:
        await _confirmRemove(book);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(_provider);
    final controller = ref.read(_provider.notifier);
    final booklist = widget.args.booklist;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: controller.loadFirst,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              surfaceTintColor: Colors.transparent,
            ),
            SliverToBoxAdapter(child: _BooklistHeader(booklist: booklist)),
            ..._body(l10n, state, controller),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(
    AppLocalizations l10n,
    BooklistDetailState state,
    BooklistDetailController controller,
  ) {
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
              onPressed: controller.loadFirst,
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
            icon: Icons.collections_bookmark_outlined,
            title: l10n.noBooklistBooks,
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
            final book = state.books[index];
            final note = book.note?.trim() ?? '';
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BookListTile(
                  book: book.toDisplay(),
                  showCover: true,
                  onTap: () => AppRoutes.openBookDetailForBook(context, book),
                  onLongPress: widget.args.canEdit
                      ? () => _confirmRemove(book)
                      : null,
                  trailing: widget.args.canEdit
                      ? PopupMenuButton<_DetailBookMenuAction>(
                          icon: const Icon(Icons.more_vert_rounded),
                          padding: EdgeInsets.zero,
                          onSelected: (action) =>
                              _onBookMenuSelected(book, action),
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: _DetailBookMenuAction.editNote,
                              child: Text(
                                note.isEmpty
                                    ? l10n.booklistAddNote
                                    : l10n.booklistEditNote,
                              ),
                            ),
                            PopupMenuItem(
                              value: _DetailBookMenuAction.remove,
                              child: Text(l10n.booklistRemoveBook),
                            ),
                          ],
                        )
                      : null,
                ),
                if (note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      note,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic,
                            height: 1.35,
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

/// Actions on one book row's "…" menu (own lists only).
enum _DetailBookMenuAction { editNote, remove }

/// Large cover + title block, then the description (collapsed to three
/// lines, tap to expand when it is longer).
class _BooklistHeader extends StatelessWidget {
  final Booklist booklist;

  const _BooklistHeader({required this.booklist});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              BooklistCover(url: booklist.coverUrl, width: 96, height: 132),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            booklist.name,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                              height: 1.2,
                            ),
                          ),
                        ),
                        if (booklist.isPrivate) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.lock_outline_rounded,
                            size: 18,
                            color: cs.onSurfaceVariant,
                          ),
                        ],
                        if (booklist.isFavorite) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.favorite_rounded,
                            size: 18,
                            color: cs.primary,
                          ),
                        ],
                      ],
                    ),
                    if (booklist.author.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            Icons.person_outline_rounded,
                            size: 16,
                            color: cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              booklist.author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    BooklistMetaPills(list: booklist),
                  ],
                ),
              ),
            ],
          ),
          if (booklist.description.isNotEmpty) ...[
            const SizedBox(height: 16),
            _ExpandableText(
              text: booklist.description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Divider(color: cs.outlineVariant),
        ],
      ),
    );
  }
}

class _ExpandableText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  const _ExpandableText({required this.text, this.style});

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  static const int _collapsedLines = 3;
  bool _expanded = false;

  // Memoized overflow measurement: the TextPainter is only rebuilt
  // when the text, style, text direction, or available width changes.
  // Rebuilding it on every layout is wasted work — the description
  // does not change between builds.
  String? _measuredText;
  TextStyle? _measuredStyle;
  TextDirection? _measuredDirection;
  double? _measuredWidth;
  bool _overflows = false;

  bool _measureOverflow(BuildContext context, double maxWidth) {
    final direction = Directionality.of(context);
    if (_measuredText == widget.text &&
        _measuredStyle == widget.style &&
        _measuredDirection == direction &&
        _measuredWidth == maxWidth) {
      return _overflows;
    }
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: _collapsedLines,
      textDirection: direction,
    )..layout(maxWidth: maxWidth);
    final overflows = painter.didExceedMaxLines;
    painter.dispose();
    _measuredText = widget.text;
    _measuredStyle = widget.style;
    _measuredDirection = direction;
    _measuredWidth = maxWidth;
    _overflows = overflows;
    return overflows;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final overflows = _measureOverflow(context, constraints.maxWidth);
        final text = Text(
          widget.text,
          style: widget.style,
          maxLines: _expanded ? null : _collapsedLines,
          overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
        );
        if (!overflows) return text;
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedSize(
                duration: AppMotion.standard,
                alignment: Alignment.topCenter,
                child: text,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
