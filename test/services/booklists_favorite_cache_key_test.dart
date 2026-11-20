import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

/// 回归（审查 v2 P1-1，2026-11-21）：收藏书单页走 Dio 时交给
/// [ZLibraryApiBase.onBooklistHtmlLoaded] 的缓存键，必须与
/// booklists_provider 读缓存用的键一致。
///
/// 曾经回调构造 URL 时漏传 `favorite:`——收藏页 HTML 被写进发现页的
/// 键（`/booklists?...`），收藏 tab 的 SWR 永不命中；且默认参数
/// （query=''/order='popular'/page=1，order 默认值见
/// booklists_provider.dart）下两个 tab 互写同一个键，私密收藏会画进
/// 公共的发现页。
///
/// 之前没抓到是因为 booklists_state_test 的假 API 自己实现了
/// `booklistsPageUrl` 并正确传了 favorite；这里必须用**真实**
/// [ZLibraryApi]（Dio 桩适配器打穿插件层，注入点见 ZLibraryApiBase
/// 构造器注释："a test seam"）。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.html);

  final String html;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    html,
    200,
    headers: {Headers.contentTypeHeader: ['text/html; charset=utf-8']},
  );
}

const String _pageHtml =
    '<html><body><div class="booklists"><z-booklist></z-booklist></div>'
    '</body></html>';

void main() {
  test('收藏页 Dio 加载的缓存键与控制器读键一致（审查 P1-1 回归）', () async {
    final captured = <String>[];
    final dio = Dio()..httpClientAdapter = _StubAdapter(_pageHtml);
    final api = ZLibraryApi(dio: dio);
    api.onBooklistHtmlLoaded = (url, html, fetchedAt) => captured.add(url);

    // 参数形态复刻 booklists_provider._loadPage 的真实调用
    // （order 恒传 state.order，默认 'popular'）。
    final response = await api.searchFavoriteBooklists(
      query: '',
      order: 'popular',
      page: 1,
    );
    expect(response.success, isTrue);

    expect(captured, hasLength(1));
    expect(Uri.parse(captured.single).path, '/booklists/favorite');
    // 读键：booklists_provider 用 booklistsPageUrl(mine:false,
    // favorite:true, …) 查缓存——写键必须逐字符等于它。
    expect(
      captured.single,
      api.booklistsPageUrl(
        mine: false,
        favorite: true,
        query: '',
        order: 'popular',
        page: 1,
      ),
    );
  });

  test('发现页回调键不受影响（防修过头）', () async {
    final captured = <String>[];
    final dio = Dio()..httpClientAdapter = _StubAdapter(_pageHtml);
    final api = ZLibraryApi(dio: dio);
    api.onBooklistHtmlLoaded = (url, html, fetchedAt) => captured.add(url);

    final response = await api.searchPublicBooklists(
      query: '',
      order: 'popular',
      page: 1,
    );
    expect(response.success, isTrue);

    expect(captured, hasLength(1));
    expect(Uri.parse(captured.single).path, '/booklists');
    expect(
      captured.single,
      api.booklistsPageUrl(
        mine: false,
        favorite: false,
        query: '',
        order: 'popular',
        page: 1,
      ),
    );
  });
}
