// Split out of `books_provider.dart` (M3): SavedBooksNotifier + savedBooksProvider.
// `books_provider.dart` re-exports this file, so existing
// imports of `package:zlibx/providers/books_provider.dart` keep working.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

import '../services/storage_service.dart';
import 'zlibrary_provider.dart';

// ── Saved Books ─────────────────────────────────────────────────────

class SavedBooksNotifier extends Notifier<AsyncValue<List<Book>>> {
  // Getters, not `late final` fields: ref.invalidate (account switch, line
  // change, logout) re-runs build() on the SAME notifier instance, and a
  // second assignment to a late final throws LateInitializationError, which
  // left the provider in an error state and blanked the library screen.
  ZLibraryApi get _api => ref.read(zlibraryApiProvider);
  StorageService get _storage => ref.read(storageServiceProvider);

  @override
  AsyncValue<List<Book>> build() {
    loadSavedBooks();
    return const AsyncValue.loading();
  }

  /// 全量拉取收藏列表。[silent] 为 true 时是后台静默 revalidate：不
  /// 置 loading 态，失败时保留已有数据（只在尚无数据时才报 error），
  /// 收藏/取消后的后台对账就用它，列表不闪一下 loading。
  Future<void> loadSavedBooks({bool silent = false}) async {
    // build() 直接调这里，而首次 build 时 state 还不存在：读 `state`
    // 会抛 StateError（'Tried to read the state of an uninitialized
    // provider'），抛在 try 之前、第一个 await 之前，整个拉取直接
    // 夭折、provider 永远卡在 loading——冷启动图书馆无限转圈就是
    // 这么来的。`stateOrNull` 在未初始化时返回 null 而不抛，正是
    // Riverpod 给 build 期读 state 的写法；初始化之后和 `state` 等价。
    final hadData = stateOrNull?.valueOrNull != null;
    if (!silent) state = const AsyncValue.loading();

    try {
      const pageSize = 100;
      final books = <Book>[];
      final seen = <int>{};
      for (var page = 1; page <= 100; page++) {
        final response = await _api.getUserSaved(page: page, limit: pageSize);
        if (!response.success) {
          throw StateError(response.error ?? 'Could not load saved books');
        }
        final batch = response.data ?? <Book>[];
        final before = seen.length;
        for (final book in batch) {
          if (seen.add(book.id)) books.add(book);
        }
        final totalPages = int.tryParse(
          response.meta?['total_pages']?.toString() ?? '',
        );
        if ((totalPages != null && page >= totalPages) ||
            batch.length < pageSize ||
            seen.length == before) {
          break;
        }
      }
      state = AsyncValue.data(books);
    } catch (e, stack) {
      // 静默对账失败：已有列表是乐观更新后的正确内容，别用 error 覆盖它。
      if (silent && hadData) return;
      state = AsyncValue.error(e, stack);
    }
  }

  /// 后台静默对账：与服务端对一遍，不动 loading、不覆盖已有列表。
  Future<void> _revalidateSilently() => loadSavedBooks(silent: true);

  /// 本地乐观更新：当前列表已有数据时才改 state；尚无数据（首屏还
  /// 在加载）时返回 false，调用方改走全量 [loadSavedBooks]。
  bool _optimisticAdd(Book book) {
    final current = state.valueOrNull;
    if (current == null) return false;
    if (current.any((b) => b.id == book.id)) return true;
    // 服务端列表是新收藏在前，乐观插入放队首，后台对账再纠正顺序。
    state = AsyncValue.data([book, ...current]);
    return true;
  }

  bool _optimisticRemove(String bookId) {
    final current = state.valueOrNull;
    if (current == null) return false;
    if (!current.any((b) => b.id.toString() == bookId)) return true;
    state = AsyncValue.data(
      current.where((b) => b.id.toString() != bookId).toList(),
    );
    return true;
  }

  /// 收藏一本书。[book] 是详情页已有的完整 [Book]（经
  /// `DisplayBook.asZLibBook` 取到）：有它才能本地乐观插入；拿不到
  /// 时退回全量拉取。成功后立即返回，后台静默对账。
  Future<bool> saveBook(String bookId, {Book? book}) async {
    try {
      final response = await _api.saveBook(bookId);
      if (!response.success) return false;
      await _storage.addFavorite(bookId);
      if (book != null && _optimisticAdd(book)) {
        unawaited(_revalidateSilently());
      } else {
        await loadSavedBooks();
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 取消收藏一本书。[reload] 为 false 时不刷新列表（批量场景由调用方统一刷新）。
  Future<bool> unsaveBook(String bookId, {bool reload = true}) async {
    try {
      final response = await _api.unsaveUserBook(bookId);
      if (!response.success) return false;
      await _storage.removeFavorite(bookId);
      if (_optimisticRemove(bookId)) {
        if (reload) unawaited(_revalidateSilently());
      } else {
        if (reload) await loadSavedBooks();
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 批量取消收藏：逐本处理（每本都已乐观移除），全部完成后只静默
  /// 对账一次，不闪 loading。
  /// 返回成功取消的数量。
  Future<int> unsaveBooks(Iterable<String> bookIds) async {
    var removed = 0;
    for (final id in bookIds) {
      if (await unsaveBook(id, reload: false)) removed++;
    }
    await loadSavedBooks(silent: true);
    return removed;
  }
}

final savedBooksProvider =
    NotifierProvider<SavedBooksNotifier, AsyncValue<List<Book>>>(
      SavedBooksNotifier.new,
    );
