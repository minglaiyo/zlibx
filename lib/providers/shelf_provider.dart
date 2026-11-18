import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import '../models/display_book.dart';
import '../models/unified_shelf_item.dart';
import 'books_provider.dart';
import 'local_collection_provider.dart';

/// 统一书架 — z站收藏 + 本地收藏（外部源 Anna/LibGen）
final unifiedShelfProvider = Provider<AsyncValue<List<UnifiedShelfItem>>>((
  ref,
) {
  final zlibAsync = ref.watch(savedBooksProvider);
  final localCollection = ref.watch(localCollectionProvider);

  if (zlibAsync is AsyncLoading) {
    return const AsyncValue.loading();
  }

  final items = <UnifiedShelfItem>[];

  final zlibData = zlibAsync.valueOrNull;
  if (zlibData != null) {
    items.addAll(zlibData.map((b) => _fromZLib(b)));
  }

  // 本地收藏是纯内存态（同步 Notifier），没有加载失败语义；新加入
  // 的在前（与收藏页"最近收藏靠前"的观感一致）。
  items.addAll(localCollection.books.map((b) => _fromLocal(b)));

  return AsyncValue.data(items);
});

UnifiedShelfItem _fromZLib(Book book) {
  return UnifiedShelfItem(
    source: ShelfSource.library,
    displayBook: book.toDisplay(),
    rawBookId: book.id.toString(),
    lastReadTime: null,
  );
}

UnifiedShelfItem _fromLocal(DisplayBook book) {
  return UnifiedShelfItem(
    source: ShelfSource.local,
    displayBook: book,
    rawBookId: book.id,
    lastReadTime: null,
  );
}
