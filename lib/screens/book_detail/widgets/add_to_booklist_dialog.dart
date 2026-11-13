import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/booklists_provider.dart';
import '../../../providers/zlibrary_provider.dart';
import '../../../services/booklist_repository.dart';
import '../../../utils/app_snack.dart';
import '../../account/widgets/create_booklist_dialog.dart';
import '../../../widgets/loading_widget.dart';

/// Picker for the signed-in user's own booklists; adds [bookId] to the
/// picked list (`GET /papi/booklist/{id}/add-book/{bookId}`).
///
/// The picker reads the full membership table once
/// (`GET /papi/booklist/current-user/{bookId}`): every list with a
/// member flag, a local name search, and an inline create row. Tapping
/// a list the book is already in removes it
/// (`remove-book/{readlistBookId}`); tapping any other adds it. The
/// dialog stays open after an add/remove (like the site's picker) so
/// the user can add the book to several lists in one go.
///
/// Returns true when the user asked to log in (the caller navigates to
/// the login page); false otherwise. The API calls and their notices
/// happen inside the dialog.
Future<bool> showAddToBooklistDialog(BuildContext context, int bookId) async {
  final loginRequested = await showDialog<bool>(
    context: context,
    builder: (context) => _AddToBooklistDialog(bookId: bookId),
  );
  return loginRequested ?? false;
}

enum _PickerPhase { loading, loggedOut, error, ready }

class _AddToBooklistDialog extends ConsumerStatefulWidget {
  final int bookId;

  const _AddToBooklistDialog({required this.bookId});

  @override
  ConsumerState<_AddToBooklistDialog> createState() =>
      _AddToBooklistDialogState();
}

class _AddToBooklistDialogState extends ConsumerState<_AddToBooklistDialog> {
  final TextEditingController _searchController = TextEditingController();

  _PickerPhase _phase = _PickerPhase.loading;
  List<BooklistMembership> _memberships = const [];
  String? _error;

  /// List ids with an add/remove currently in flight.
  final Set<int> _busyIds = <int>{};

  late final BooklistRepository _repository;

  @override
  void initState() {
    super.initState();
    _repository = BooklistRepository(ref.read(zlibraryApiProvider));
    Future<void>.microtask(_load);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (ref.read(authProvider).user == null) {
      if (!mounted) return;
      setState(() => _phase = _PickerPhase.loggedOut);
      return;
    }
    final response =
        await _repository.getBooklistsForBook(widget.bookId);
    if (!mounted) return;
    if (response.success && response.data != null) {
      setState(() {
        _memberships = response.data!;
        _phase = _PickerPhase.ready;
      });
      return;
    }
    setState(() {
      _error = response.error;
      _phase = _PickerPhase.error;
    });
  }

  /// The memberships matching the local name search.
  List<BooklistMembership> get _visible {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _memberships;
    return _memberships
        .where((m) => m.title.toLowerCase().contains(query))
        .toList();
  }

  /// Replace one membership row's entry id in the local table.
  void _setEntryId(int booklistId, int? entryId) {
    setState(() {
      _memberships = _memberships
          .map(
            (m) => m.booklistId == booklistId
                ? BooklistMembership(
                    booklistId: m.booklistId,
                    title: m.title,
                    readlistBookId: entryId,
                  )
                : m,
          )
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.selectBooklist),
      content: SizedBox(
        width: double.maxFinite,
        child: _body(l10n),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }

  Widget _body(AppLocalizations l10n) {
    switch (_phase) {
      case _PickerPhase.loading:
        return const SizedBox(
          height: 120,
          child: Center(child: LoadingWidget.inline(size: 28)),
        );
      case _PickerPhase.loggedOut:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.loginToViewBooklists),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.login),
            ),
          ],
        );
      case _PickerPhase.error:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error ?? l10n.error),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                setState(() => _phase = _PickerPhase.loading);
                unawaited(_load());
              },
              child: Text(l10n.retry),
            ),
          ],
        );
      case _PickerPhase.ready:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: l10n.searchBooklists,
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: l10n.clear,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.add_rounded),
                        title: Text(l10n.createBooklist),
                        onTap: _createAndAdd,
                      ),
                      const Divider(height: 1),
                      for (final membership in _visible)
                        _membershipRow(l10n, membership),
                      if (_visible.isEmpty && _memberships.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(l10n.noBooklists),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
    }
  }

  Widget _membershipRow(
    AppLocalizations l10n,
    BooklistMembership membership,
  ) {
    final busy = _busyIds.contains(membership.booklistId);
    final member = membership.isMember;
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        member ? Icons.bookmark_rounded : Icons.bookmark_outline_rounded,
        color: member ? cs.primary : null,
      ),
      title: Text(
        membership.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: busy ? const LoadingWidget.inline() : null,
      onTap: busy ? null : () => _toggle(membership),
    );
  }

  /// Add the book to a list it is not in, or remove it from one it is
  /// in. The row's flag updates immediately; the dialog stays open.
  Future<void> _toggle(BooklistMembership membership) async {
    if (_busyIds.contains(membership.booklistId)) return;
    setState(() => _busyIds.add(membership.booklistId));
    try {
      if (membership.isMember) {
        await _remove(membership);
      } else {
        await _add(membership);
      }
    } finally {
      if (mounted) setState(() => _busyIds.remove(membership.booklistId));
    }
  }

  Future<void> _add(BooklistMembership membership) async {
    final l10n = AppLocalizations.of(context)!;
    final response = await _repository.addBookToBooklistEntry(
      booklistId: membership.booklistId,
      bookId: widget.bookId,
    );
    if (!mounted) return;
    if (response.success) {
      _setEntryId(membership.booklistId, response.data);
      ref
          .read(booklistsControllerProvider.notifier)
          .noteBookAdded(membership.booklistId.toString());
      showAppSnack(context, l10n.addToBooklistSuccess);
      return;
    }
    showAppSnack(
      context,
      l10n.addToBooklistFailed(response.error ?? ''),
    );
  }

  Future<void> _remove(BooklistMembership membership) async {
    final l10n = AppLocalizations.of(context)!;
    final entryId = membership.readlistBookId;
    if (entryId == null) return;
    final response = await _repository.removeBookFromBooklist(
      booklistId: membership.booklistId,
      readlistBookId: entryId,
    );
    if (!mounted) return;
    if (response.success) {
      _setEntryId(membership.booklistId, null);
      showAppSnack(context, l10n.booklistBookRemoved);
      return;
    }
    showAppSnack(
      context,
      l10n.booklistRemoveBookFailed(response.error ?? ''),
    );
  }

  /// Inline create: a new list with this book already in it (the
  /// create call carries the book id), then reload the membership
  /// table so the new row shows its member flag.
  Future<void> _createAndAdd() async {
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
    final response = await _repository.createBooklist(
      title: result.title,
      description: result.description,
      color: result.color,
      isPrivate: result.isPrivate,
      bookId: widget.bookId,
    );
    if (!mounted) return;
    if (response.success) {
      showAppSnack(context, l10n.booklistCreated);
      setState(() => _phase = _PickerPhase.loading);
      await _load();
      return;
    }
    showAppSnack(
      context,
      l10n.booklistCreateFailed(response.error ?? ''),
    );
  }
}
