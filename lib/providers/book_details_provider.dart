// Split out of `books_provider.dart` (M3): bookDetailsProvider + BookIdentifier (its parameter type).
// `books_provider.dart` re-exports this file, so existing
// imports of `package:zlibx/providers/books_provider.dart` keep working.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/utils/diagnostics.dart';

import '../services/book_detail_page_repository.dart';
import '../services/storage_service.dart';
import 'auth_provider.dart';
import 'zlibrary_provider.dart';

// ── Book Details ────────────────────────────────────────────────────

/// 详情页附加信息（卷/ISBN/IPFS/评分）的新鲜窗口：卷/ISBN/IPFS 是
/// 版本常量，只有两个社区评分会变（兴趣分另有 eapi interestScore
/// 兜底）——7 天内的旧评分换取重复打开整段跳过几百 KB 的 HTML 下载
/// （TTL 惯例同 BooklistHtmlCache）。
const _bookDetailExtrasTtl = Duration(days: 7);

/// 附加信息这一条路的总预算（缓存未命中时的一次抓取，含可能的后台
/// 求解）。插件里 HTML 的 receiveTimeout 是 300 s——慢链路收完几百 KB
/// 确实可能要那么久，但那只是几行装饰字段，正文不该陪它等：过这个点
/// 就放弃本轮，用过期缓存兜底，下次打开再补。
const _bookDetailExtrasBudget = Duration(seconds: 25);

/// 后台求解的预算：比 [_bookDetailExtrasBudget] 小，好让求解自己先结
/// 束——外层 timeout 只是放弃等待，WebView 求解仍在背后跑完它自己那
/// 60 s。
const _bookDetailExtrasSolverTimeout = Duration(seconds: 15);

/// 详情页缓存键：详情页的 PATH（每版本稳定）。手动剥掉 query/
/// fragment，不走 Uri.parse——它会把这个未编码的中文路径百分号编
/// 码，同一个 href 的键就因写法不同而漂移（CI 2026-11-13：测试夹具
/// 的中文 slug 被编码成 %E5%90%88…，缓存全 miss）。
String bookDetailExtrasKey(String href) {
  final query = href.indexOf('?');
  final fragment = href.indexOf('#');
  var end = href.length;
  if (query >= 0 && query < end) end = query;
  if (fragment >= 0 && fragment < end) end = fragment;
  return href.substring(0, end);
}

bool _extrasFresh(Map<String, dynamic> extras) {
  final fetchedAt = extras['fetchedAt'];
  if (fetchedAt is! int) return false;
  // 格式标记：关联书单上线后写出的条目都带 `booklists` 键（可为空
  // 表）。上线前写入的旧条目没有它——按过期处理、重抓一次补齐，
  // 否则新特性会被 7 天 TTL 的旧缓存整周遮住（覆盖安装保留 Hive
  // 数据，装机当天就会踩中）。
  if (extras['booklists'] is! List) return false;
  return DateTime.now().millisecondsSinceEpoch - fetchedAt <
      _bookDetailExtrasTtl.inMilliseconds;
}

/// [BookDetailExtras] → 可持久化的 JSON（7 个 metadata 字段 + 关键词
/// 列表 + 关联书单最小卡片；fetchedAt 由 storage 层盖章）。
Map<String, dynamic> _extrasJsonOf(BookDetailExtras extras) {
  final json = <String, dynamic>{
    'volume': extras.metadata.volume,
    'isbn10': extras.metadata.isbn10,
    'isbn13': extras.metadata.isbn13,
    'ipfsCid': extras.metadata.ipfsCid,
    'ipfsCidBlake2b': extras.metadata.ipfsCidBlake2b,
    'ratingInterest': extras.metadata.ratingInterest,
    'ratingQuality': extras.metadata.ratingQuality,
    if (extras.keywords.isNotEmpty) 'keywords': extras.keywords,
    // 恒写（含空表）：键的存在即新格式标记，见 [_extrasFresh]。
    'booklists': [
      for (final list in extras.relatedBooklists) _relatedBooklistJson(list),
    ],
  };
  return json;
}

/// 关联书单卡片的持久化形态：只存展示与导航需要的字段（id/name/url/
/// cover/count）。previewBooks 不进缓存——点开书单页会自己拉正文，
/// 卡片列表本身不带它们也无损。
Map<String, dynamic> _relatedBooklistJson(Booklist list) => {
  'id': list.id,
  'name': list.name,
  'url': list.url,
  if (list.coverUrl.isNotEmpty) 'cover': list.coverUrl,
  if (list.count != null) 'count': list.count,
};

/// 缓存 JSON → 关联书单列表（[bookDetailExtrasProvider] 那条腿的
/// `booklists` 键）。逐条容错：坏条目跳过、键缺失给空——旧缓存没有
/// 这一键时就是空列表（下次 TTL 过期自然补上），绝不让详情页报错。
List<Booklist> bookDetailRelatedBooklists(Map<String, dynamic>? extras) {
  final raw = extras == null ? null : extras['booklists'];
  if (raw is! List) return const [];
  final lists = <Booklist>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final id = entry['id'];
    final name = entry['name'];
    final url = entry['url'];
    if (id is! String || id.isEmpty) continue;
    if (name is! String || name.isEmpty) continue;
    if (url is! String || url.isEmpty) continue;
    final count = entry['count'];
    final cover = entry['cover'];
    lists.add(
      Booklist(
        id: id,
        name: name,
        url: url,
        coverUrl: cover is String ? cover : '',
        count: count is int ? count : int.tryParse('${count ?? ''}'),
      ),
    );
  }
  return lists;
}

/// 缓存 JSON → 合并进书本体。逐字段容错取值：缓存是手改/旧版本的
/// JSON 时最坏也只是丢字段，绝不让详情页报错。
String? _extrasString(Object? value) => value is String ? value : null;

/// 附加字段 JSON 并进书本体（[bookDetailsProvider] 的正文 +
/// [bookDetailExtrasProvider] 的装饰字段）。copyWith 的空值语义是
/// “保留原值”，所以附加字段只会补行、不会抹掉 eapi 已有的值。
List<String>? _extrasStringList(Object? value) =>
    value is List ? value.whereType<String>().toList() : null;

Book applyBookDetailExtras(Book book, Map<String, dynamic> extras) =>
    book.copyWith(
      keywords: _extrasStringList(extras['keywords']),
      volume: _extrasString(extras['volume']),
      isbn10: _extrasString(extras['isbn10']),
      isbn13: _extrasString(extras['isbn13']),
      ipfsCid: _extrasString(extras['ipfsCid']),
      ipfsCidBlake2b: _extrasString(extras['ipfsCidBlake2b']),
      ratingInterest: _extrasString(extras['ratingInterest']),
      ratingQuality: _extrasString(extras['ratingQuality']),
    );

/// 详情页正文（eapi 的小 JSON：书名/作者/简介/文件信息）。
///
/// autoDispose：详情页关掉后无人 watch 即释放缓存。此前常驻内存，
/// 长会话逐本累积（每本详情是全量 [Book]）；相似书链路中每一页
/// 详情始终 watch 自己的 identifier，不会产生重复请求。
///
/// 只发 eapi 这一个请求，不等详情页 HTML——2026-11-15 拆分。
/// 此前（1.5.8 起）两者在同一个 Future 里 await：eapi 早到了也要等
/// 那几百 KB 的 HTML 页（最多 5 跳、receiveTimeout 300 s，命中
/// DiamWall 还要起 WebView 求解），正文跟着一起卡住——这就是
/// “详情页比以前的版本慢”的来源（1.5.7 及更早只有 eapi 一个
/// 请求）。附加字段改由 [bookDetailExtrasProvider] 独立加载，
/// 到达后由 [BookDetailScreen] 并进本文。
///
/// eapi 自己失败照旧抛出：正文没有兜底可退，页面显示错误 + 重试。
///
/// 两层持久缓存（2026-11-21，诊断包实测驱动——短 hash 书每次打开都
/// 白付"注定失败的 fetch1 + 按标题解析"两个往返，重开同一本 0 缓存
/// 全重来，屏上计时 2.3s→5.0s）：
///  * 详情正文 7 天 TTL（library 盒）：重开同一本零请求秒开；
///  * 短 hash → eapi 真 hash 解析映射（library 盒，无 TTL，坏映射
///    自愈）：解析一次后，以后每次打开直接用真 hash，3 连发变 1 发。
final bookDetailsProvider = FutureProvider.autoDispose
    .family<Book, BookIdentifier>((ref, identifier) async {
      final api = ref.watch(zlibraryApiProvider);
      final storage = ref.watch(storageServiceProvider);
      // 缓存优先：7 天内的正文直接用（路由 href 仍然后挂，入口行为
      // 与网络路径一致）。
      final cachedJson = await storage.getBookDetailCache(identifier.bookId);
      if (cachedJson != null) {
        final cached = Book.fromJson(cachedJson);
        final routeHref = identifier.href;
        return (routeHref == null || routeHref.isEmpty)
            ? cached
            : cached.copyWith(href: routeHref);
      }
      // 解析映射在 vendor 内部查（resolveCacheLookup，接到 library
      // 盒）——命中就直接用真 hash，跳过"短 hash 必失败的第一发"。
      final response = await api.getBookInfo(
        identifier.bookId,
        identifier.hashId,
        title: identifier.title,
      );
      if (!response.success) {
        final user = ref.read(authProvider).user;
        final fallback = await _bookFromDetailPage(
          api,
          storage,
          identifier,
          userId: user?.id,
          userKey: user?.remixUserkey,
        );
        if (fallback != null) return fallback;
        throw StateError(response.error ?? 'Failed to load book details');
      }
      final book = response.data;
      if (book == null) {
        throw StateError('Book details response did not contain a book');
      }
      // 正文无条件回写缓存（unawaited，不挡返回）。
      unawaited(storage.putBookDetailCache(identifier.bookId, book.toJson()));
      // 路由带的 href 优先（列表页给的那个）；eapi 自己的 href 也
      // 认，路由没带时附加字段靠它定位。
      final routeHref = identifier.href;
      return (routeHref == null || routeHref.isEmpty)
          ? book
          : book.copyWith(href: routeHref);
    });

/// eapi 取不到书时，从这本书自己的详情页 HTML 读正文。
///
/// 触发条件收窄成"eapi 根本没法寻址这本书"——路由带的 hash 不是
/// eapi 的 6 位 hash。2026-11-24 实测的两条硬事实决定了这个判据：
///  * 网页侧只有 10 位短 hash（`/book/Ej8q7Dmrv9/…`），eapi 对它回
///    `400 无效哈希`；换成同长度但错误的 6 位值同样被拒，所以它是
///    真正的每书密钥，不能猜。
///  * 能把 id 映射到 6 位 hash 的只有搜索返回，而 `POST
///    /eapi/book/search` 现在整条路 `400 Access denied`（在凭证之前
///    就被拒）；`/json/search`、`/json/get-book`、`/api/get-book/`、
///    `/papi/book/search` 探过一遍：要么返回 HTML 壳，要么 404。站点上
///    已经没有任何一条网页通道能拿到 eapi hash。
///  * 站点还按镜像语言本地化错误文案（中文镜像回 `无效哈希`，不是
///    `Invalid hash`），所以这里不按错误字符串分流，只按 hash 形态。
///
/// 6 位 hash 却失败 = 书真没了/会话坏了，HTML 页不会给出相反结论，
/// 那种错误必须原样抛给用户，不能偷偷换通道。
///
/// 求解允许前台：走到这里屏幕上本来就只有"加载失败 + 重试"，弹验证
/// 页比弹错误强。失败（含求解不成）返回 null，由调用方抛原错误。
Future<Book?> _bookFromDetailPage(
  ZLibraryApi api,
  StorageService storage,
  BookIdentifier identifier, {
  String? userId,
  String? userKey,
}) async {
  final href = identifier.href;
  if (href == null || href.isEmpty) return null;
  if (identifier.hashId.length == 6) return null;
  final ApiResponse<Book> result;
  try {
    result = await BookDetailPageRepository(api).fetchBook(
      href: href,
      userId: userId,
      userKey: userKey,
    );
  } catch (_) {
    // 兜底自己炸了（网络、解析、注入的 fake）不算新错误：原 eapi 错误
    // 才是用户该看到的那一条。
    return null;
  }
  final book = result.data;
  if (!result.success || book == null) return null;
  // 与 eapi 路径同一份 7 天正文缓存：HTML 正文字段少几项（阅读链接、
  // 收藏状态这些 eapi 才有的东西），但一本 eapi 永远取不到的书，重复
  // 打开时省掉几百 KB 的 HTML 下载比补齐那几项更要紧。附加字段仍由
  // bookDetailExtrasProvider 独立并进来。
  unawaited(storage.putBookDetailCache(identifier.bookId, book.toJson()));
  return book;
}

/// 详情页 HTML 上的附加字段（卷/ISBN/IPFS/评分），按
/// [bookDetailExtrasKey] 缓存；并进本文见 [applyBookDetailExtras]。
///
/// 与正文彻底独立（互不等待）：
///  * 持久缓存新鲜 → 直接返回，零请求。
///  * 未命中/过期 → 抓一次并回写；整段只给
///    [_bookDetailExtrasBudget] 预算，命中墙时只允许后台求解
///    （[_bookDetailExtrasSolverTimeout]，不弹可见验证页）——用户
///    此刻在读的是正文，评分行缺着比被 WebView 盖一层强。
///  * 失败/超时 → 退回过期缓存（可能为 null），永不抛。
///
/// 返回 null 意思是“这一轮拿不到附加字段”，不是错误状态。
///
/// 预算只是 UI 的等待上限：超时后同一条在途抓取（见
/// [loadBookDetailExtrasDeduped]）在后台继续跑完并回写缓存——
/// 慢链路上这一轮的放弃不再作废整次下载，下次打开直接命中。
final bookDetailExtrasProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, href) async {
      final key = bookDetailExtrasKey(href);
      final storage = ref.watch(storageServiceProvider);
      final cached = storage.getBookDetailExtrasSync(key);
      if (cached != null && _extrasFresh(cached)) return cached;
      final api = ref.watch(zlibraryApiProvider);
      // 会话取快照（同旧行为）：登录态变化由
      // invalidateAccountScopedProviders 统一重跑，这里不自己转圈。
      final user = ref.read(authProvider).user;
      final json = await loadBookDetailExtrasDeduped(
        api,
        storage,
        href,
        userId: user?.id,
        userKey: user?.remixUserkey,
      ).timeout(_bookDetailExtrasBudget, onTimeout: () => null);
      return json ?? cached;
    });

/// 同一页面的在途加载表（键 = [bookDetailExtrasKey]，与存储键同一
/// 套归一化——query/fragment 写法漂移的同页共享同一条 Future）：
/// 详情页中途退出再进、搜索预取与手动打开撞车，都不再各起一条几百
/// KB 的下载——慢链路上那是实打实的带宽，两条并行等于各减一半速。
/// 条目在 Future 完全落定后移除（预算超时的那轮仍在里面跑，直到它
/// 后台回写完缓存）。
final _inflightExtras = <String, Future<Map<String, dynamic>?>>{};

/// 附加字段加载的公共入口，[bookDetailExtrasProvider] 与搜索预取共
/// 用：持久缓存新鲜 → 零请求直返；否则抓一次（Dio 先行，撞墙只允许
/// 后台求解，[_bookDetailExtrasSolverTimeout]）并回写存储。失败返回
/// null，永不抛。无 UI 预算——调用方要限时自己 `.timeout`。
Future<Map<String, dynamic>?> loadBookDetailExtrasDeduped(
  ZLibraryApi api,
  StorageService storage,
  String href, {
  String? userId,
  String? userKey,
}) {
  final key = bookDetailExtrasKey(href);
  final existing = _inflightExtras[key];
  if (existing != null) return existing;
  final future = _loadExtrasCore(
    api,
    storage,
    href,
    userId: userId,
    userKey: userKey,
  );
  _inflightExtras[key] = future;
  unawaited(future.whenComplete(() {
    if (identical(_inflightExtras[key], future)) {
      _inflightExtras.remove(key);
    }
  }));
  return future;
}

Future<Map<String, dynamic>?> _loadExtrasCore(
  ZLibraryApi api,
  StorageService storage,
  String href, {
  String? userId,
  String? userKey,
}) async {
  final key = bookDetailExtrasKey(href);
  final cached = storage.getBookDetailExtrasSync(key);
  if (cached != null && _extrasFresh(cached)) return cached;
  try {
    final result = await BookDetailPageRepository(api).fetch(
      href: href,
      userId: userId,
      userKey: userKey,
      allowVisibleSolver: false,
      solverTimeout: _bookDetailExtrasSolverTimeout,
    );
    if (result.success && result.data != null) {
      final json = _extrasJsonOf(result.data!);
      unawaited(storage.mergeBookDetailExtras(key, json));
      return json;
    }
    logIgnored(
      'book_details_metadata',
      StateError(result.error ?? 'book detail page failed'),
    );
  } on Object catch (error) {
    logIgnored('book_details_metadata', error);
  }
  return null;
}

class BookIdentifier {
  final String bookId;
  final String hashId;

  /// Book title, used only to resolve the real eapi hash when the
  /// stored hash is a webpage short hash (see `getBookInfo`).
  final String? title;

  /// The book's webpage path (`/book/{hash}/{slug}.html`) when the
  /// list response that produced this book carried it. Used only to
  /// fetch the detail-page metadata (volume / ISBN / IPFS) that the
  /// eapi does not carry; null skips that fetch silently.
  final String? href;

  BookIdentifier(this.bookId, this.hashId, {this.title, this.href});

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BookIdentifier &&
        other.bookId == bookId &&
        other.hashId == hashId &&
        other.title == title &&
        other.href == href;
  }

  @override
  int get hashCode =>
      bookId.hashCode ^ hashId.hashCode ^ title.hashCode ^ href.hashCode;
}
