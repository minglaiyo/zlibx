import 'package:flutter/foundation.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/utils/diagnostics.dart';

import 'comment_book_ref.dart';


/// 评论列表的书目反查 + 跳详情控制器，"我的评论"页与用户主页评论
/// 列表共用（此前两屏各持一份逐行级重复实现：refs 缓存、
/// openingBookIds 防重点、预取循环、跳详情流程）。
///
/// 职责：
/// 1. [prefetch]：评论加载后按 bookId 去重、上限 [maxPrefetch] 本，
///    逐本串行标题搜索反查 hash + 封面（[resolveCommentBookRef]，
///    一次请求两用）；每解析完一本通知一次，对应书名行即时刷出
///    封面。
/// 2. [openBookDetail]：优先用预取缓存的 hash，缺失时现场反查；
///    解析中 bookId 进 [openingBookIds]（书名行尾转圈、防重复点
///    击）；拿到 hash 后经 [onReady] 交回屏侧导航，失败经 [onFail]
///    提示且不跳转（不进残缺详情页）。
///
/// 网络行为与原实现完全一致：逐本串行、上限 10（避免并发风暴）。
/// 页面销毁（[dispose]）或新一次 [prefetch]（[prefetch] 代际递
/// 增）都会让旧循环自然退出。
class CommentBookRefController extends ChangeNotifier {
  CommentBookRefController({required this.api});

  final ZLibraryApi api;

  /// 预取上限：评论一次最多拉 500 条，逐本搜索会放大请求量，只
  /// 预取前 [maxPrefetch] 本（足够铺满几屏）；未预取到的行显示
  /// 占位图，点按时仍会解析并跳转。
  static const int maxPrefetch = 10;

  /// bookId → 标题搜索反查结果（hash + 封面）。
  final Map<int, CommentBookRef> refs = {};

  /// 正在解析书 hash 并准备跳详情的 bookId：书名行尾转圈。
  final Set<int> openingBookIds = {};

  bool _disposed = false;

  /// [prefetch] 代际：新列表预取时递增，旧的 worker 循环比对后
  /// 自行退出（替代原来散在各屏的 `if (!mounted) return`）。
  int _generation = 0;

  CommentBookRef? refFor(int bookId) => refs[bookId];

  bool isOpening(int bookId) => openingBookIds.contains(bookId);

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  /// 预取书名行的 hash + 封面。[items] 传评论列表的
  /// `(bookId, 书名)`。同一 bookId 只搜一次；已解析过的跳过；
  /// 单本失败不阻塞其余（保持占位图，点按时经 [openBookDetail]
  /// 再试）。每解析完一本 emit 一次。逐本串行执行，避免并发风暴。
  Future<void> prefetch(List<({int bookId, String title})> items) async {
    final token = ++_generation;
    final queue = <({int bookId, String title})>[];
    final seen = <int>{};
    for (final item in items) {
      if (item.bookId <= 0 || !seen.add(item.bookId)) continue;
      if (refs[item.bookId]?.hasHash ?? false) continue;
      if (queue.length >= maxPrefetch) break;
      queue.add(item);
    }
    for (final item in queue) {
      if (_disposed || _generation != token) return;
      try {
        final info = await resolveCommentBookRef(api, item.bookId, item.title);
        if (_disposed || _generation != token) return;
        if (info != null) {
          refs[item.bookId] = info;
          _emit();
        }
      } catch (_) {
        // 单本失败保持占位图，点按时重试。
      }
    }
  }

  /// 书名行 → 书籍详情。评论接口只给 bookId + 书名，没有书 hash；
  /// 详情页靠 hash 拉全量数据，所以先用标题搜索反查同 id 书目的
  /// eapi hash（顺带取回封面），再经 [onReady] 交回最小 [Book]。
  /// 预取缓存里有 hash 就不再搜索。返回是否发起了跳转。
  Future<bool> openBookDetail({
    required int bookId,
    required String title,
    required void Function(Book book) onReady,
    required void Function() onFail,
  }) async {
    if (bookId <= 0 || openingBookIds.contains(bookId)) return false;
    openingBookIds.add(bookId);
    _emit();
    try {
      var hash = refs[bookId]?.hash ?? '';
      if (hash.isEmpty) {
        final info = await resolveCommentBookRef(api, bookId, title);
        if (_disposed) return false;
        if (info != null) {
          refs[bookId] = info;
          hash = info.hash;
          _emit();
        }
      }
      if (hash.isEmpty) {
        onFail();
        return false;
      }
      onReady(Book(id: bookId, title: title, hash: hash));
      return true;
    } catch (error) {
      logIgnored('comment_book_ref', error);
      onFail();
      return false;
    } finally {
      openingBookIds.remove(bookId);
      _emit();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
