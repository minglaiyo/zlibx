// Split out of `books_provider.dart` (M3): HistoryCoverNotifier + historyCoverProvider + isBookFavoritedProvider.
// `books_provider.dart` re-exports this file, so existing
// imports of `package:zlibx/providers/books_provider.dart` keep working.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/utils/diagnostics.dart';

import '../services/storage_service.dart';
import 'zlibrary_provider.dart';

class HistoryCoverNotifier extends Notifier<Map<String, String>> {
  final Set<String> _attempted = <String>{};

  /// 有界并发（4）+ FIFO：元数据落地前每个封面失败的行都会来要一次
  /// 详情请求，50 行的一页在慢镜像上瞬间能排进几十个请求；排队限流
  /// 让它们慢慢消化，详情请求本身不快也没关系（结果异步叠加回
  /// state）。_attempted 照旧防止行重建导致的重试循环。
  static const int _maxInFlight = 4;
  final List<Book> _queue = <Book>[];
  var _inFlight = 0;

  @override
  Map<String, String> build() => const <String, String>{};

  Future<void> resolveCover(Book book) async {
    final id = book.id.toString();
    if (book.id == 0 || _attempted.contains(id)) return;
    _attempted.add(id);
    _queue.add(book);
    _drain();
  }

  void _drain() {
    while (_inFlight < _maxInFlight && _queue.isNotEmpty) {
      final book = _queue.removeAt(0);
      _inFlight++;
      _resolve(book).whenComplete(() {
        _inFlight--;
        _drain();
      });
    }
  }

  Future<void> _resolve(Book book) async {
    final id = book.id.toString();
    try {
      final response = await ref.read(zlibraryApiProvider).getBookInfo(
            id,
            book.hash ?? '',
            title: book.title,
          );
      final cover = response.data?.cover;
      if (response.success && cover != null && cover.isNotEmpty) {
        state = {...state, id: cover};
      }
    } catch (error) {
      // No usable cover: keep the placeholder. _attempted prevents
      // retry loops when the row rebuilds.
      logIgnored('history_cover', error);
    }
  }
}

final historyCoverProvider =
    NotifierProvider<HistoryCoverNotifier, Map<String, String>>(
      HistoryCoverNotifier.new,
    );

// ── Favorites Check ─────────────────────────────────────────────────

/// autoDispose：每本书一个缓存项；详情页关掉即释放，切换账号时
/// [invalidateAccountScopedProviders] 本来就会整体失效它。
final isBookFavoritedProvider = FutureProvider.autoDispose.family<bool, String>((
  ref,
  bookId,
) async {
  final storage = ref.watch(storageServiceProvider);
  return await storage.isFavorite(bookId);
});
