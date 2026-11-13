// Split out of `books_provider.dart` (M3): DownloadedBooksNotifier + downloadedBooksProvider.
// `books_provider.dart` re-exports this file, so existing
// imports of `package:zlibx/providers/books_provider.dart` keep working.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/utils/diagnostics.dart';

import '../services/download_stats_repository.dart';
import '../services/storage_service.dart';
import 'auth_provider.dart';
import 'zlibrary_provider.dart';

// ── Downloaded Books ────────────────────────────────────────────────

/// 一页 dstats 的流水线结果。[error] 非 null 时 [books] 为空，异常在
/// 按序消费到该页时原样上抛（保留旧的失败语义）；被终点之后的
/// listEnded 丢弃的 speculative 页则带着 error 静默消失。
typedef _StatsPageResult = ({List<Book> books, bool viaSolver, Object? error});

/// 云端下载历史（账号维度的逐次下载记录，包含其他设备 / 网页端产生
/// 的下载）。
///
/// 数据源是网站的「下载历史」页 `/users/downloads`（服务端渲染 HTML，
/// 每次下载一行、50 行/页、?page=N 翻页）——这是全账号的下载日志。
/// eapi 的 `/eapi/user/book/downloaded` 不是这份数据：其他设备 /
/// 网页端的记录不在里面（2026-11-12 用户报告），只拿它来补元数据
/// （作者/封面/格式/大小），dstats 行本身只有 书id+标题+链接+时间。
///
/// 此前实现只读 eapi 列表（全量翻页），但 eapi 里根本没有其他设备 /
/// 网页端的记录——那些书永远看不到。现在与 [SavedBooksNotifier]
/// 同构：全量翻页 + 可静默对账，页面打开 / 下拉时都能拿到最新列表。
/// 2026-11-13 起加载分三段：dstats 窗口化预取、元数据持久缓存先行
/// 播种、eapi 只补缺失（见 [loadDownloadedBooks] 的文档）。
class DownloadedBooksNotifier extends Notifier<AsyncValue<List<Book>>> {
  // Getter, not a `late final` field: ref.invalidate (account switch,
  // line change, logout) re-runs build() on the SAME notifier instance,
  // and a second assignment to a late final throws LateInitializationError
  // — see SavedBooksNotifier above.
  ZLibraryApi get _api => ref.read(zlibraryApiProvider);

  /// 单调递增的拉取代号：每次拉取取下一个，只有最新一代能写 state。
  /// 打开页面、下拉刷新、账号切换可能让多次拉取重叠，慢的那次不
  /// 能用自己的旧页覆盖新一代已上屏的列表。
  int _generation = 0;

  /// 静默对账是否正在跑：build() 从缓存上屏后立刻起一个静默刷新，
  /// 历史页 initState 的 microtask 随后又会调一次——两次都是静默
  /// 对账，后一次只会重复拉第 1 页（代际守卫本就会丢弃旧的那次），
  /// 所以直接省掉。非静默调用不受影响，照常接管。
  bool _silentRefreshInFlight = false;

  /// 上次完整拉取完成的时刻（本会话内）：[silentRefreshTtl] 之内的
  /// 静默刷新直接跳过——完整翻页是整条链路最贵的一段，而列表缓存 +
  /// 元数据缓存已经让重复打开显示完整内容；下拉刷新传 force: true
  /// 照常全量拉。build()（invalidate，账号/线路切换）时清零，新
  /// 账号的缓存内容不同，不继承旧账号的 TTL。
  DateTime? _lastFullLoadAt;
  static const Duration silentRefreshTtl = Duration(minutes: 3);

  @override
  AsyncValue<List<Book>> build() {
    final cached = _readCachedHistory();
    if (cached.isNotEmpty) {
      // Cache-first: paint the last known list immediately (first
      // paint ~0 s from cache), then refresh silently in the
      // background — the silent path never shrinks the visible list
      // and never replaces it with an error, so the cache stays up
      // until the fresh list catches up.
      _lastFullLoadAt = null;
      unawaited(loadDownloadedBooks(silent: true));
      return AsyncValue.data(cached);
    }
    _lastFullLoadAt = null;
    loadDownloadedBooks();
    return const AsyncValue.loading();
  }

  /// The cached server history for the signed-in account, in display
  /// order, or empty when signed out / nothing cached. Read
  /// synchronously so build() can paint it without awaiting.
  List<Book> _readCachedHistory() {
    final userId = ref.read(authProvider).user?.id;
    if (userId == null || userId.isEmpty) return const <Book>[];
    return ref
        .read(storageServiceProvider)
        .getServerDownloadHistorySyncForAccount(userId);
  }

  /// 全量拉取云端下载历史。dstats 是权威列表；eapi 列表只用来补
  /// 元数据，它失败不影响历史本身。服务端按下载时间倒序（最新在
  /// 前），按序拼接即保持该顺序，UI 的"按日期"排序仍等于服务端顺
  /// 序。[silent] 为 true 时是后台静默对账：不置 loading 态，失败时
  /// 保留已有数据（只在尚无数据时才报 error）——页面打开 / build()
  /// 的后台对账用它；下拉刷新传 [force] = true，绕过静默 TTL 强制
  /// 全量拉，但同样不闪 loading。
  ///
  /// 三段结构（2026-11-13 重排；此前 eapi 元数据要全部翻完才叠加、
  /// 且每次打开都全量重跑，慢镜像上封面要等几十秒）：
  ///
  /// 1. dstats 窗口化预取：按页序上屏不变，抓取并行——page 1 先行，
  ///    返回非空后按窗口（2→4 逐波递增）发后续页，消费一页补发一
  ///    页；撞 solver 的页之后暂停发新 speculative 页（WebView 升级
  ///    很贵，不堆投机请求），后续快页恢复。终点之后在途的页直接
  ///    丢弃（issue() 把异常折进结果，绝不会变成未处理错误）。
  /// 2. 元数据持久缓存先行：eapi 的作者/封面/格式/大小按 book id 存
  ///    Hive（书级数据与账号无关），第一页 dstats 上屏时就带着封面
  ///    出现——此前要等 eapi 全部翻完。
  /// 3. dstats 拉完后只补缺失：缓存没覆盖到的 id（新下载）才翻
  ///    eapi，每页到达即叠加；缺失集清空 / 整页无新增 / 到达
  ///    total_pages 即停。缓存全覆盖时 eapi 循环整段跳过（重复打开
  ///    0 请求）。失败只损失元数据，照旧容忍。
  ///
  /// 代际守卫：每次调用取一个新代号，只有最新一代能写 state——
  /// 打开页面、下拉刷新、账号切换可能让多次拉取重叠，慢的那次不
  /// 能用自己的旧页覆盖新一代已上屏的列表。
  Future<void> loadDownloadedBooks({
    bool silent = false,
    bool force = false,
  }) async {
    // 静默对账已在跑时不再重开一次（见 _silentRefreshInFlight）。
    if (silent && _silentRefreshInFlight) return;
    // 静默 TTL：本会话刚完整拉取过就不再翻页（下拉 force 不受限；
    // 列表为空时不跳，首次加载没有可跳的依据）。
    if (silent &&
        !force &&
        _lastFullLoadAt != null &&
        DateTime.now().difference(_lastFullLoadAt!) < silentRefreshTtl &&
        stateOrNull?.valueOrNull?.isNotEmpty == true) {
      return;
    }
    if (silent) _silentRefreshInFlight = true;
    // build() 直接调这里，而首次 build 时 state 还不存在：读 `state`
    // 会抛 StateError（见 SavedBooksNotifier 上的注释），`stateOrNull`
    // 在未初始化时返回 null 而不抛，正是 Riverpod 给 build 期读 state
    // 的写法。
    final hadData = stateOrNull?.valueOrNull != null;
    final generation = ++_generation;
    bool isCurrent() => generation == _generation;
    if (!silent) state = const AsyncValue.loading();
    final repository = DownloadStatsRepository(_api);
    final records = <Book>[];
    final seen = <String>{};
    // 元数据表：持久缓存先播种（第一页 dstats 上屏即带封面/作者），
    // eapi 只补缺失并逐页并入。
    final meta = <int, Book>{
      ...ref.read(storageServiceProvider).getDownloadedBookMetadataSync(),
    };

    /// 当前累积记录叠加已到的元数据：只补空字段，dstats 自己的字段
    /// 不动。同一本书下载多次是多条独立记录，各自叠加。
    List<Book> overlay() => [
          for (final record in records)
            meta[record.id] == null
                ? record
                : record.copyWith(
                    author: meta[record.id]!.author,
                    cover: meta[record.id]!.cover,
                    extension: meta[record.id]!.extension,
                    filesize: meta[record.id]!.filesize,
                    filesizeString: meta[record.id]!.filesizeString,
                  ),
        ];

    /// 上屏一次累积列表。两条守卫：空累积不上屏（元数据先到时不能
    /// 把 loading 闪成空历史）；绝不把可见列表换短（静默对账时旧
    /// 列表先顶着，新列表没长到旧长度前不替换）。
    void paint() {
      if (!isCurrent() || records.isEmpty) return;
      final next = overlay();
      final current = stateOrNull?.valueOrNull;
      if (current != null && next.length < current.length) return;
      state = AsyncValue.data(next);
    }

    try {
      // ── 1. dstats：窗口化预取流水线 ──
      // page 1 先行（它决定后面有没有东西值得预取）；之后按序消费，
      // 消费一页补发一页。issue() 把异常折进结果：被放弃的 speculative
      // 页永远不抛未处理异常，真正的失败在按序消费时原样上抛（墙错
      // 误等，失败语义与旧的串行循环一致）。
      const maxPages = 30;
      var window = 2;
      var nextToIssue = 2;
      var issueAllowed = true; // 撞 solver 的页之后暂停，直到又见快页
      var listEnded = false;
      final pending = <int, Future<_StatsPageResult>>{};

      void topUp() {
        while (!listEnded &&
            issueAllowed &&
            nextToIssue <= maxPages &&
            pending.length < window) {
          final page = nextToIssue++;
          pending[page] = _issueStatsPage(repository, page);
        }
      }

      var consume = 1;
      while (consume <= maxPages && !listEnded) {
        final result = consume == 1
            ? await _issueStatsPage(repository, consume)
            : await (pending.remove(consume) ??
                _issueStatsPage(repository, consume));
        if (!isCurrent()) return;
        if (result.error != null) throw result.error!;
        final batch = result.books;
        // 撞 solver 的页之后暂停发新 speculative 抓取；后续快页恢复。
        issueAllowed = !result.viaSolver;
        final before = seen.length;
        for (final book in batch) {
          // 键含时间戳：同一本书下载多次是合法的多条记录，只有"整页
          // 逐条都和之前完全相同"才算没有新增。
          if (seen.add(
            '${book.id}|${book.downloadedAt?.toIso8601String()}|${book.title}',
          )) {
            records.add(book);
          }
        }
        // 终止：空页，或整页都是已见过的记录（服务端忽略 page 参数时
        // 每页回同一批，靠这个不空转）。
        if (batch.isEmpty || seen.length == before) {
          listEnded = true;
          // 终点之后的 speculative 页直接丢弃。
          pending.clear();
        } else {
          window = window < 4 ? window + 1 : window;
          topUp();
        }
        paint();
        consume++;
      }
      if (!isCurrent()) return;

      // ── 2+3. eapi：只补缺失的元数据 ──
      // 持久缓存（播种）没覆盖到的 id（新下载）才翻页；每页到达即
      // 叠加一次。失败只损失元数据（与旧行为一致），不影响列表。
      final missing = <int>{
        for (final record in records)
          if (!meta.containsKey(record.id)) record.id,
      };
      if (missing.isNotEmpty) {
        try {
          await _fillMissingMetadata(
            missing: missing,
            meta: meta,
            onPage: () {
              if (isCurrent()) paint();
            },
          );
        } catch (e) {
          logIgnored('downloaded_meta', e);
        }
        if (!isCurrent()) return;
        // 新学到的元数据并回持久缓存（顺带把播种的原样写回，幂等）。
        unawaited(
          ref.read(storageServiceProvider).mergeDownloadedBookMetadata(meta),
        );
      }

      // 最终上屏：不受 paint 的缩短守卫限制，服务端已删的记录照
      // 常消失。
      final finalList = overlay();
      state = AsyncValue.data(finalList);
      _lastFullLoadAt = DateTime.now();
      // 缓存最后的上屏列表：下次打开先从缓存秒出，再静默刷新。
      // 只存非空的完整列表——空结果（失败/中途返回）绝不覆盖好缓存。
      if (finalList.isNotEmpty) {
        unawaited(
          ref
              .read(storageServiceProvider)
              .saveServerDownloadHistory(finalList),
        );
      }
    } catch (e, stack) {
      // 静默对账失败：已有列表是最后已知的好数据，别用 error 覆盖它。
      // build() 刚把缓存上屏时 state 尚未初始化，调用时算的 hadData
      // 是 false——这里按报错时的 state 再判一次，缓存列表同样受保护。
      if (silent && (hadData || stateOrNull?.valueOrNull != null)) return;
      if (!isCurrent()) return;
      state = AsyncValue.error(e, stack);
    } finally {
      if (silent) _silentRefreshInFlight = false;
    }
  }

  /// 一页 `/users/downloads`（50 行，最新在前），以及它走的路径：
  /// [viaSolver] 为 true 表示这页经过了 WebView solver（流水线用它
  /// 暂停发新 speculative 页）。
  ///
  /// 镜像会用浏览器验证墙拦页面路由（HTTP 503 browser check page，
  /// eapi 端点不拦）：撞墙的那一页改走 WebView challenge solver 过墙
  /// 重取；过墙后 wall cookies 回灌 Dio，后续页恢复快路径直连。solver
  /// 也失败时抛出原始墙错误（可重试），绝不把墙页解析成空历史。
  Future<({List<Book> books, bool viaSolver})> _fetchStatsPage(
    DownloadStatsRepository repository,
    int page,
  ) async {
    final response = await repository.fetchPage(page: page);
    if (response.success) {
      return (books: response.data ?? const <Book>[], viaSolver: false);
    }
    if (repository.isChallengeError(response.error)) {
      final books = await _fetchStatsPageViaSolver(
        repository,
        page,
        originalError: response.error ?? 'download history failed',
      );
      return (books: books, viaSolver: true);
    }
    throw StateError(
      response.error ?? 'Could not load download history',
    );
  }

  /// 流水线的单页抓取：把 [_fetchStatsPage] 的异常折进结果——被终点
  /// 之后的 listEnded 丢弃的 speculative 页绝不能以未处理异步异常的
  /// 形式炸掉 zone；真正的失败在按序消费到该页时原样上抛。
  Future<_StatsPageResult> _issueStatsPage(
    DownloadStatsRepository repository,
    int page,
  ) async {
    try {
      final result = await _fetchStatsPage(repository, page);
      return (books: result.books, viaSolver: result.viaSolver, error: null);
    } catch (e) {
      return (books: const <Book>[], viaSolver: false, error: e);
    }
  }

  /// 一页 dstats 的 solver 回退：装会话 → WebView 过墙取渲染后的
  /// HTML → wall cookies 回灌 Dio → 解析。HTML 不是 dstats 页（落在
  /// 登录页等）或过墙失败时抛原始墙错误——wrong-page 守卫保证绝不满
  /// 足于一个"看似成功"的错误页。解析失败时再走一次可见 solver：无
  /// 头抓到的可能是空 503 页，或标题里没有验证墙关键字、墙的 JS 还
  /// 没跑完的墙页；可见页让墙在看得见的 WebView 里跑完，两次都解
  /// 析失败才抛原始墙错误。
  Future<List<Book>> _fetchStatsPageViaSolver(
    DownloadStatsRepository repository,
    int page, {
    required String originalError,
  }) async {
    final user = ref.read(authProvider).user;
    final url = repository.pageUrl(page: page);
    final html = await repository.fetchViaSolver(
      url,
      userId: user?.id,
      userKey: user?.remixUserkey,
    );
    if (html == null) throw StateError(originalError);
    var parsed = repository.parsePage(html);
    if (parsed == null) {
      // solver 回来了 HTML，但它根本不是下载历史页：无头 WebView 抓
      // 到的可能是一个空的 503 报错页，或者标题里没有验证墙关键字、
      // 墙的 JS 在慢网速下还没跑完的墙页。不要直接按这页报错——再走
      // 一次可见 solver，让墙在看得见的 WebView 里跑完，解析那份 HTML。
      final visibleHtml = await repository.fetchViaVisibleSolver(
        url,
        userId: user?.id,
        userKey: user?.remixUserkey,
      );
      if (visibleHtml == null) throw StateError(originalError);
      parsed = repository.parsePage(visibleHtml);
      if (parsed == null) throw StateError(originalError);
    }
    return parsed;
  }

  /// eapi downloaded 列表翻页，补齐 [missing] 里还没有元数据的 id：
  /// 每页到达即并入 [meta] 并回调 [onPage]（渐进叠加），缺失集清空 /
  /// 整页没有任何新 id / 到达 total_pages 即停。失败抛给调用方容忍。
  Future<void> _fillMissingMetadata({
    required Set<int> missing,
    required Map<int, Book> meta,
    required void Function() onPage,
  }) async {
    const pageSize = 100;
    for (var page = 1; page <= 100; page++) {
      final response = await _api.getUserDownloaded(
        page: page,
        limit: pageSize,
      );
      if (!response.success) {
        throw StateError(
          response.error ?? 'Could not load download metadata',
        );
      }
      final batch = response.data ?? const <Book>[];
      final before = meta.length;
      for (final book in batch) {
        missing.remove(book.id);
        meta[book.id] = book;
      }
      onPage();
      // 终止条件故意不用 batch.length < pageSize：镜像可能把 limit
      // 压到比 100 小，那只说明本页比请求的短，不代表没有下一页。
      // "缺失集清空"、"到达 total_pages"或"整页没有任何新 id（服务
      // 端忽略 page 参数时每页回同一批）"才可靠。注意中间那条必须
      // 是"任何新 id"而不是"找到缺失"：缺失的 id 可能是服务端已删
      // 的书、永远找不到，但它们之间的页还在带来别的元数据。
      if (missing.isEmpty) break;
      final totalPages = int.tryParse(
        response.meta?['total_pages']?.toString() ?? '',
      );
      if ((totalPages != null && page >= totalPages) ||
          meta.length == before) {
        break;
      }
    }
  }
}

final downloadedBooksProvider =
    NotifierProvider<DownloadedBooksNotifier, AsyncValue<List<Book>>>(
      DownloadedBooksNotifier.new,
    );

/// Resolved detail covers for cloud history rows, keyed by book id.
///
/// The downloaded endpoint's cover value never loads, so a row whose
/// listed cover fails falls back to the detail endpoint's cover — the
/// same cover the detail page shows once its fetch completes.
