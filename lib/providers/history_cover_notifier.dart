// Split out of `books_provider.dart` (M3): HistoryCoverNotifier + historyCoverProvider + isBookFavoritedProvider.
// `books_provider.dart` re-exports this file, so existing
// imports of `package:zlibx/providers/books_provider.dart` keep working.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/utils/diagnostics.dart';

import '../services/storage_service.dart';
import 'zlibrary_provider.dart';


/// A cover the history list cannot use (plan item 11): empty, or one of
/// the two dead values the metadata endpoint hands out — a
/// `collections//<hash>.jpg` URL (the directory part is empty, the file
/// is not there) and the site's own no-cover placeholder
/// `/img/cover-not-exists.png` (it would load fine and masquerade as a
/// real cover, so it must never be requested at all). A real cover lives
/// under `collections/<dir>/...` and passes.
bool isInvalidHistoryCover(String? cover) {
  if (cover == null || cover.trim().isEmpty) return true;
  final value = cover.trim();
  if (value.contains('collections//')) return true;
  if (value.contains('cover-not-exists.png')) return true;
  return false;
}

/// Resolved detail covers for cloud history rows, keyed by book id.
///
/// The downloaded endpoint's cover value never loads, so a row whose
/// listed cover fails falls back to the detail endpoint's cover — the
/// same cover the detail page shows once its fetch completes. Only
/// rows actually on screen ask (the row widget calls [resolveCover]),
/// at most 3 detail requests in flight, each book once per session;
/// a failed resolve keeps the placeholder and never retries.
class HistoryCoverNotifier extends Notifier<Map<String, String>> {
  final Set<String> _attempted = <String>{};

  /// 有界并发（3）+ FIFO：元数据落地前每个封面失败的行都会来要一次
  /// 详情请求，50 行的一页在慢镜像上瞬间能排进几十个请求；排队限流
  /// 让它们慢慢消化，详情请求本身不快也没关系（结果异步叠加回
  /// state）。_attempted 照旧防止行重建导致的重试循环。
  static const int _maxInFlight = 3;
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
      final response = await ref
          .read(zlibraryApiProvider)
          .getBookInfo(id, book.hash ?? '', title: book.title);
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
final isBookFavoritedProvider = FutureProvider.autoDispose.family<bool, String>(
  (ref, bookId) async {
    final storage = ref.watch(storageServiceProvider);
    return await storage.isFavorite(bookId);
  },
);
