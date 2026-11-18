import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/annas_archive.dart';
import '../models/display_book.dart';
import '../services/annas_models.dart';
import '../services/hive_service.dart';
import '../utils/app_log.dart';


/// 本地收藏（方案 C2）：Anna's Archive / LibGen 的书进不了 z站 的
/// 收藏体系（远端列表按账号存），长按快捷面板给外部源一个"收藏到
/// 本地"的落点。数据整体存 Hive settings box 的一个 JSON blob（与
/// 书架分类同一模式）：条目少、体积小，每次改写全量重写。
///
/// 序列化的是 [BookData]（详情页从收藏条目打开时必须重建出带
/// original 的 DisplayBook——`_ExternalBookDetail` 强解包
/// asAnnaBookData/asLibgenBookData，且详情 URL 用 bookData.link），
/// 所以 link 必须原样保留，不能用 md5 现拼。
class LocalCollectionState {
  const LocalCollectionState(this.books);

  /// 收藏的书，新加入的在前。
  final List<DisplayBook> books;

  bool contains(BookSource source, String id) => books.any(
    (book) => book.source == source && book.id == id,
  );
}

class LocalCollectionNotifier extends Notifier<LocalCollectionState> {
  @override
  LocalCollectionState build() => _load();

  static const _storageKey = 'external_collection_v1';

  LocalCollectionState _load() {
    final raw = HiveService.settingsBox.get(_storageKey);
    if (raw is! String) return const LocalCollectionState([]);
    try {
      final data = jsonDecode(raw) as List<dynamic>;
      final books = <DisplayBook>[];
      for (final entry in data) {
        if (entry is! Map<String, dynamic>) continue;
        final book = _bookFromEntry(entry);
        if (book != null) books.add(book);
      }
      return LocalCollectionState(books);
    } on Object catch (error) {
      AppLog.report(
        'Could not load local collection: ${error.runtimeType}',
        tag: 'local_collection',
      );
      return const LocalCollectionState([]);
    }
  }

  Future<void> _save(List<DisplayBook> books) async {
    state = LocalCollectionState(books);
    final data = jsonEncode([
      for (final book in books)
        _entryFromBook(book),
    ]);
    try {
      await HiveService.settingsBox.put(_storageKey, data);
    } catch (error) {
      // 与书架分类同一策略：落盘失败不丢内存态，下次成功保存全量重写。
      AppLog.report(
        'Could not persist local collection: ${error.runtimeType}',
        tag: 'local_collection',
      );
    }
  }

  /// 收藏条目的 JSON 形态。original 必须是 [BookData]（收藏入口只收
  /// 外部源的书）；万一不是，只落能拿到的展示字段，link 为 null 时
  /// 读回侧会用 md5 兜底。
  Map<String, dynamic> _entryFromBook(DisplayBook book) {
    final data = book.original;
    final isBookData = data is BookData;
    return {
      'source': book.source.name,
      'md5': book.id,
      'title': book.title,
      'author': book.author,
      'thumbnail': book.cover,
      'tag': book.tag,
      'link': isBookData ? data.link : null,
      'publisher': isBookData ? data.publisher : null,
      'info': isBookData ? data.info : null,
      'catalog': isBookData ? data.source : null,
    };
  }

  /// 收藏一本外部源的书（已在收藏里则先移除再插入，保证置顶）。
  Future<void> add(DisplayBook book) async {
    await _save([
      book,
      ...state.books.where(
        (item) => !(item.source == book.source && item.id == book.id),
      ),
    ]);
  }

  Future<void> remove(BookSource source, String id) async {
    await _save(
      state.books
          .where((item) => !(item.source == source && item.id == id))
          .toList(),
    );
  }

  // ── 书架数据备份（方案 C3）────────────────────────────────────

  /// 备份导出用的条目形态（与 [_entryFromBook] 同一张表，导入侧可原
  /// 样吃回）。
  List<Map<String, dynamic>> exportEntries() => [
    for (final book in state.books) _entryFromBook(book),
  ];

  /// 备份导入：按 来源+md5 去重合并，返回新加入的条数。坏条目丢弃
  /// （读回侧 [_bookFromEntry] 自带逐条过滤）。
  Future<int> importEntries(List<Map<String, dynamic>> entries) async {
    final incoming = <DisplayBook>[];
    for (final entry in entries) {
      final book = _bookFromEntry(entry);
      if (book == null) continue;
      if (state.books.any(
        (item) => item.source == book.source && item.id == book.id,
      )) {
        continue;
      }
      if (incoming.any(
        (item) => item.source == book.source && item.id == book.id,
      )) {
        continue;
      }
      incoming.add(book);
    }
    if (incoming.isEmpty) return 0;
    await _save([...incoming, ...state.books]);
    return incoming.length;
  }
}

final localCollectionProvider =
    NotifierProvider<LocalCollectionNotifier, LocalCollectionState>(
      LocalCollectionNotifier.new,
    );

/// 收藏条目 → DisplayBook（original 带上重建的 BookData）。缺 md5 或
/// title 的坏条目丢弃（JSON 被外部改坏时不至于整表失效——load 时逐条
/// try 也行，但逐条过滤让损坏面最小）。
DisplayBook? _bookFromEntry(Map<String, dynamic> entry) {
  final sourceName = entry['source']?.toString();
  final md5 = entry['md5']?.toString();
  final title = entry['title']?.toString();
  if (md5 == null ||
      md5.isEmpty ||
      title == null ||
      title.isEmpty ||
      (sourceName != BookSource.annasArchive.name &&
          sourceName != BookSource.libgen.name)) {
    return null;
  }
  final bookData = BookData(
    title: title,
    author: entry['author']?.toString(),
    thumbnail: entry['thumbnail']?.toString(),
    // link 缺失时用 md5 现拼 Anna 的规范相对路径兜底；LibGen 条目正常
    // 都带 link，兜底值只防手改坏数据，不保证可用。
    link: entry['link']?.toString() ?? '/md5/$md5',
    md5: md5,
    publisher: entry['publisher']?.toString(),
    info: entry['info']?.toString(),
    source: entry['catalog']?.toString(),
  );
  return DisplayBook(
    id: md5,
    title: title,
    author: bookData.author,
    cover: bookData.thumbnail,
    tag: ArchiveParsing.formatFromInfo(bookData.info),
    source: sourceName == BookSource.libgen.name
        ? BookSource.libgen
        : BookSource.annasArchive,
    original: bookData,
  );
}
