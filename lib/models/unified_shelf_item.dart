import '../models/display_book.dart';

/// 书架来源。library = z站远端收藏（服务端同步）；local = 本地收藏
/// （外部源 Anna/LibGen 的书进不了 z站收藏体系，落在设备本地）。
enum ShelfSource { library, local }

/// 统一书架条目 — z站收藏
class UnifiedShelfItem {
  final ShelfSource source;
  final DisplayBook displayBook;
  final String rawBookId;
  final int? lastReadTime;

  String get categoryKey => '${source.name}:$rawBookId';

  const UnifiedShelfItem({
    required this.source,
    required this.displayBook,
    required this.rawBookId,
    this.lastReadTime,
  });
}
