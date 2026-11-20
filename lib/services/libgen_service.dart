// Ported from warreth/OpenlibExtended (AGPL-3.0) — Anna's Archive / LibGen
// book sources. Original file: lib/services/libgen_service.dart
// zlibx is AGPL-3.0 (see LICENSE); upstream MIT attribution for
// shiyi-0x7f/olib-mobile is preserved in LICENSE.

// Dart imports:
import 'dart:async';

// Package imports:
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:meta/meta.dart';

// Project imports:
import 'package:zlibx/services/annas_archieve.dart';
import 'package:zlibx/services/external_logger.dart';
import 'package:zlibx/utils/diagnostics.dart';
import 'package:zlibx/services/http_client.dart';
import 'package:zlibx/services/instance_manager.dart'; // For MirrorService (re-exported from the catalogue).
import 'package:zlibx/services/mirror_speed_test.dart';

/// Library Genesis book-info + download service.
///
/// The libgen.li/bz/vg family serves book details on `ads.php?md5=<32 hex>`
/// pages: a `table#main` with a "Title:/Author(s):/Publisher:/Year:" text
/// row, a cover `<img>` and one `get.php?md5=...&key=...` anchor. The key
/// is minted per page load and the link 307-redirects to the CDN file, so
/// it doubles as a native download URL - no webview needed.
class LibgenService {
  // Same desktop-Chrome UA as every other app HTTP client
  // (kDefaultUserAgent, http_client.dart — one definition, W1).
  static const _browserHeaders = {'User-Agent': kDefaultUserAgent};

  final Dio _dio;
  final AppLogger _logger = AppLogger();

  LibgenService({Dio? dio})
    : _dio =
          dio ??
          createDioWithLogging(
            options: BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              headers: _browserHeaders,
              followRedirects: true,
              maxRedirects: 5,
            ),
          );

  /// Fetches and parses a libgen `ads.php` page.
  ///
  /// [url] is the link from search results: either absolute
  /// (`<mirror>/ads.php?md5=...`) or bare (`/ads.php?md5=...`, resolved
  /// against the first enabled libgen mirror - mirrors come from
  /// open-slum.org). When the page's host fails, the other enabled
  /// libgen mirrors are tried by swapping the host, keeping path and
  /// query.
  ///
  /// The page is fetched fresh on every call - the get.php key it
  /// contains is per-page-load and must never be cached.
  Future<BookInfoData?> bookInfo(String url, {String? donationKey}) async {
    // Download order: a fresh device-side speed measurement (Mirrors
    // page > 测速) ranks the mirrors fastest-first; without one this
    // falls back to SLUM order, exactly like before.
    final mirrors = await MirrorSpeedTest().rankedUrls(MirrorService.libgen);
    final candidates = _candidateUrls(url, mirrors);

    Object? lastError;
    for (final candidate in candidates) {
      try {
        _logger.debug(
          'Fetching libgen ads page',
          tag: 'LibgenService',
          metadata: {'url': candidate},
        );
        final baseUrl = Uri.parse(candidate).origin;
        final response = await _dio.get(
          candidate,
          options: Options(headers: {'Referer': '$baseUrl/index.php'}),
        );
        if (response.statusCode != 200) continue;

        // Phase 4: Rust bridge when injected; on any bridge failure the
        // hook un-registers itself and the Dart parse takes over.
        BookInfoData? data;
        if (libgenAdsPageParseOverride != null) {
          try {
            data = await libgenAdsPageParseOverride!(
              response.data.toString(),
              baseUrl,
              candidate,
            );
          } on Object catch (_) {
            libgenAdsPageParseOverride = null;
            data = parseAdsPage(response.data.toString(), baseUrl, candidate);
          }
        } else {
          data = parseAdsPage(response.data.toString(), baseUrl, candidate);
        }
        if (data != null) return data;

        _logger.warning(
          'Libgen ads page did not parse',
          tag: 'LibgenService',
          metadata: {'url': candidate},
        );
      } catch (e) {
        lastError = e;
        _logger.debug(
          'Libgen mirror failed, trying next',
          tag: 'LibgenService',
          metadata: {'url': candidate, 'error': e.toString()},
        );
      }
    }

    if (lastError != null) {
      _logger.error(
        'All libgen mirrors failed for book info',
        tag: 'LibgenService',
        error: lastError,
      );
    }
    return null;
  }

  List<String> _candidateUrls(String url, List<String> mirrors) {
    if (mirrors.isEmpty) return const [];

    final effective = url.startsWith('http')
        ? url
        : '${mirrors.first}${url.startsWith('/') ? url : '/$url'}';
    final origin = Uri.parse(effective).origin;
    return [
      if (mirrors.contains(origin)) effective,
      for (final mirror in mirrors)
        if (mirror != origin) swapHost(effective, mirror),
    ];
  }

  /// Replaces [url]'s scheme + host with [newBaseUrl]'s, keeping its
  /// path and query intact.
  @visibleForTesting
  String swapHost(String url, String newBaseUrl) {
    final original = Uri.parse(url);
    final replacement = Uri.parse(newBaseUrl);
    final port = replacement.hasPort ? ':${replacement.port}' : '';
    final query = original.query.isNotEmpty ? '?${original.query}' : '';
    return '${replacement.scheme}://${replacement.host}$port'
        '${original.path}$query';
  }

  /// Extracts just the cover URL from an `ads.php` page, or null when
  /// the page has no cover (empty src) or does not parse. Public static
  /// so both [bookInfo] and the lazy list-cover lookup share one
  /// implementation.
  static String? parseAdsCover(String html, String baseUrl) {
    final document = html_parser.parse(html);
    final img = document.querySelector('table#main img');
    final src = img?.attributes['src'];
    if (src == null || src.isEmpty) return null;
    return src.startsWith('http') ? src : '$baseUrl$src';
  }

  /// 会话级封面缓存：md5 → 封面 URL。重复搜索、滚回已看过的页都零
  /// 请求；封面 URL 不含会话性质的 key,跨会话持久化留待有需要再加。
  /// 上限 500（审查 v2 P3）：条目极小,超限整表清空——会话缓存的语义
  /// 就是"丢了也不心疼"。
  static final Map<String, String> _coverCache = {};

  /// 失败负缓存（审查 v2 P2-1）：镜像全挂/无封面时记录时间,5 分钟内
  /// 不再打 ads.php——否则滚出视口的卡片一回来就把整个镜像循环重放
  /// 一遍（autoDispose provider 销毁即忘）。
  static final Map<String, DateTime> _failedAt = {};
  static const Duration _failureBackoff = Duration(minutes: 5);

  /// 封面懒抓并发上限：一页搜索 25 行,25 个 provider 同时 build 会把
  /// 镜像的 ads.php 打成风暴；限 4 路排队。
  static int _coverFetchesInFlight = 0;
  static final List<Completer<void>> _coverWaiters = [];

  Future<void> _acquireCoverSlot() async {
    if (_coverFetchesInFlight < 4) {
      _coverFetchesInFlight++;
      return;
    }
    final waiter = Completer<void>();
    _coverWaiters.add(waiter);
    // 被唤醒即继承名额（审查 v2 P2-1）：release 不做"先减后加"，唤醒
    // 者直接把名额接走——旧实现减完到 waiter 加回之间的微任务窗口里，
    // 快路径可以插队，把并发顶到 5-6。
    await waiter.future;
  }

  void _releaseCoverSlot() {
    // 名额优先交接给队首 waiter（计数不落回 4 以下，快路径无机可乘）；
    // 无人排队才真正释放。计数恒等于"持坑者数量"，不漂移。
    if (_coverWaiters.isNotEmpty) {
      _coverWaiters.removeAt(0).complete();
      return;
    }
    _coverFetchesInFlight--;
  }

  /// 搜索行懒加载封面：抓 [adsUrl]（搜索行带的 ads.php?md5=… 链接）
  /// 并只解析封面 URL。libgen.li 的封面桶按库分流（主库
  /// `/covers/<数字分片>/<md5>.jpg`、fiction 库
  /// `/fictioncovers/<分片>/<md5>.jpg`,2026-11-20 实测）,分片 id 搜索
  /// 行里拿不到——逐书抓 ads.php 是唯一可靠的路。结果按 md5 记入
  /// [_coverCache]；取不到（镜像全挂/无封面）返回 null,卡片保持占位
  /// 图,下次进入再试。
  Future<String?> coverFor(String adsUrl) async {
    final md5 =
        RegExp(r'[?&]md5=([0-9a-fA-F]{32})').firstMatch(adsUrl)?.group(1);
    if (md5 == null) return null;
    final cached = _coverCache[md5];
    if (cached != null) return cached;
    final failedAt = _failedAt[md5];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _failureBackoff) {
      return null; // 负缓存窗口内：不再打镜像
    }

    await _acquireCoverSlot();
    try {
      final mirrors = await MirrorSpeedTest().rankedUrls(MirrorService.libgen);
      for (final candidate in _candidateUrls(adsUrl, mirrors)) {
        try {
          final baseUrl = Uri.parse(candidate).origin;
          final response = await _dio.get(
            candidate,
            options: Options(headers: {'Referer': '$baseUrl/index.php'}),
          );
          if (response.statusCode != 200) continue;
          final cover = parseAdsCover(response.data.toString(), baseUrl);
          if (cover != null) {
            _coverCache[md5] = cover;
            if (_coverCache.length > 500) _coverCache.clear();
            _failedAt.remove(md5);
            return cover;
          }
        } on Object catch (error) {
          // 换下一个镜像。逐镜像失败也记账（审查 v2 P2-2）。
          logIgnored('libgen_cover', error);
        }
      }
      // 全镜像失败：进负缓存窗口。
      _failedAt[md5] = DateTime.now();
      return null;
    } finally {
      _releaseCoverSlot();
    }
  }

  /// Parses a libgen `ads.php` page into [BookInfoData]. Public so tests
  /// can feed captured pages without network.
  ///
  /// Extracts the "Title:/Author(s):/Publisher:/Year:/Series:" row of
  /// the `table#main`, the cover `<img>`, and the get.php download link
  /// (stored absolute in [BookInfoData.mirror]). Returns null on markup
  /// this parser does not recognize - never throws.
  BookInfoData? parseAdsPage(String html, String baseUrl, String url) {
    try {
      final document = html_parser.parse(html);

      final getHref = document
          .querySelector('a[href*="get.php?md5="]')
          ?.attributes['href'];
      if (getHref == null) return null;

      final mainTable = document.querySelector('table#main');
      if (mainTable == null) return null;

      // The metadata row: "Title: ... <br> Author(s): ... <br> ...".
      // The row's raw text keeps label ordering; fields are split on
      // their labels because cover links and stray anchors may appear
      // between them.
      String rowText = '';
      for (final row in mainTable.querySelectorAll('tr')) {
        final text = row.text;
        if (text.contains('Title:') && text.contains('Author')) {
          rowText = _collapseWhitespace(text);
          break;
        }
      }
      if (rowText.isEmpty) return null;

      final fields = _labeledFields(rowText);
      final title = fields['Title'];
      if (title == null || title.isEmpty) return null;

      final md5 =
          RegExp(r'[?&]md5=([0-9a-fA-F]{32})').firstMatch(url)?.group(1) ??
          RegExp(r'[?&]md5=([0-9a-fA-F]{32})').firstMatch(getHref)?.group(1) ??
          title;

      // Cover: the img inside the main table near the metadata row.
      // Shares the selector with [parseAdsCover] so both see the
      // same element.
      final src = mainTable.querySelector('img')?.attributes['src'];
      final thumbnail = (src != null && src.isNotEmpty)
          ? _absolute(src, baseUrl)
          : null;

      final series = fields['Series'];
      final year = fields['Year'];
      final publisher = [
        if ((fields['Publisher'] ?? '').isNotEmpty) fields['Publisher'],
        if ((year ?? '').isNotEmpty) year,
        if ((series ?? '').isNotEmpty) 'Series: $series',
      ].join(', ');

      final info = [
        if ((fields['Language'] ?? '').isNotEmpty) fields['Language'],
      ].join(', ');

      return BookInfoData(
        title: title,
        author: (fields['Author(s)'] ?? '').isEmpty
            ? 'Unknown'
            : fields['Author(s)'],
        thumbnail: thumbnail,
        publisher: publisher.isEmpty ? 'Unknown' : publisher,
        info: info.isEmpty ? null : info,
        link: url,
        md5: md5,
        format: _formatFrom(html, url),
        mirror: _absolute(getHref, baseUrl),
        description: null,
      );
    } catch (e) {
      _logger.warning(
        'Libgen ads page parse failed',
        tag: 'LibgenService',
        error: e.toString(),
      );
      return null;
    }
  }

  /// Splits "Title: A Series: B Author(s): C" on known labels. Value of
  /// a label runs until the next label or end of text.
  static const _labels = [
    'Title:',
    'Series:',
    'Author(s):',
    'Author:',
    'Publisher:',
    'Year:',
    'ISBN:',
    'Language:',
    'Size:',
    'Pages:',
  ];

  Map<String, String> _labeledFields(String text) {
    final fields = <String, String>{};
    for (var i = 0; i < _labels.length; i++) {
      final label = _labels[i];
      final start = text.indexOf(label);
      if (start == -1) continue;
      final valueStart = start + label.length;
      // Value ends at the next label that occurs after this one.
      var end = text.length;
      for (final other in _labels) {
        final idx = text.indexOf(other, valueStart);
        if (idx != -1 && idx < end) end = idx;
      }
      fields[label.substring(0, label.length - 1)] = _collapseWhitespace(
        text.substring(valueStart, end),
      );
    }
    return fields;
  }

  /// File format: from the get.php link or page when it carries an
  /// extension hint; defaults to epub. Libgen pages carry no explicit
  /// format field, so only a real `.<ext>` token counts - the ads
  /// scripts and crypto addresses would otherwise match loose words.
  String _formatFrom(String html, String url) {
    for (final source in [url, html]) {
      final match = RegExp(
        r'[?&](?:ext|format)=\w*?(epub|pdf|mobi|azw3?|cbr|cbz|djvu)|'
        r'\.(epub|pdf|mobi|azw3?|cbr|cbz|djvu)(?=["<\s?])',
        caseSensitive: false,
      ).firstMatch(source);
      final ext = match?.group(1) ?? match?.group(2);
      if (ext != null) return ext.toLowerCase();
    }
    return 'epub';
  }

  String _absolute(String href, String baseUrl) {
    if (href.startsWith('http')) return href;
    return '$baseUrl${href.startsWith('/') ? href : '/$href'}';
  }

  String _collapseWhitespace(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

// ──────────────────────────────────────────────────────────────────
// Phase 4: injectable Rust parse hook. Same contract as the
// external_search hook; when null (default) the Dart parseAdsPage
// above is used as the fallback. NOTE: the Dart parseAdsPage logs via
// _logger on failure — the Rust hook path returns None silently and
// the same "try next mirror" behavior applies.
// ──────────────────────────────────────────────────────────────────
Future<BookInfoData?> Function(String html, String baseUrl, String url)?
libgenAdsPageParseOverride;
