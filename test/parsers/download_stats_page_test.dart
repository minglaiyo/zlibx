import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/services/download_stats_repository.dart';

/// [parseDownloadStatsPage] 解析测试。
///
/// 结构依据真实抓取：zh.z-library.sk 保存的「下载历史」页
/// （2026-11-12，page=1 共 50 行 `tr.dstats-row`）——这里取代表性的
/// 几行做夹具：正常行（带 data-th）、无 data-th 的行、缺 data-item_id
/// 的坏行、空标题的坏行。
const _pageHtml = '''
<html><body><table>
<tbody>
<tr class="dstats-row" data-item_id="23787383">
  <td class="lg-w-60 hidden-xs" style="padding-left: 16px;">1</td>
  <td class="lg-w-120" style="white-space: nowrap;">
    <span class="hidden-xs">11.11.2026</span>
    <span class="visible-xs">11.11.26</span>
    <p style="color: var(--gray-7); padding: 0;">21:02</p>
  </td>
  <td class="lg-w-530" style="max-width: 530px;">
    <div class="book-title">
      <a href="https://zh.z-library.sk/book/eOWaxzXxjb/%E7%94%B7%E4%BA%BA.html">男人就愛吃這套！讓他銷魂飛天的52招口愛技巧</a>
    </div>
  </td>
  <td class="col-buttons">
    <div class="book-rating-dstats button-element">
      <div class="book-rating " data-th=""><i class="zlibicon-star"></i></div>
    </div>
  </td>
</tr>
<tr class="dstats-row" data-item_id="30325900">
  <td class="lg-w-60 hidden-xs" style="padding-left: 16px;">2</td>
  <td class="lg-w-120" style="white-space: nowrap;">
    <span class="hidden-xs">10.11.2026</span>
    <span class="visible-xs">10.11.26</span>
    <p style="color: var(--gray-7); padding: 0;">16:45</p>
  </td>
  <td class="lg-w-530" style="max-width: 530px;">
    <div class="book-title">
      <a href="/book/0OZdLaWajd/%E4%B8%AD%E5%9B%BD%E6%B0%91%E4%BF%97%E6%B8%B8.html">中国民俗游 民间风俗自助游完全手册 （上册）</a>
    </div>
  </td>
  <td class="col-buttons">
    <div class="book-rating-dstats button-element">
      <div class="book-rating " data-th="350405ea172483af193113ba2c84ec7b"><i class="zlibicon-star"></i></div>
    </div>
  </td>
</tr>
<tr class="dstats-row">
  <td class="lg-w-60 hidden-xs">3</td>
  <td class="lg-w-120"><span class="hidden-xs">09.11.2026</span><p>10:00</p></td>
  <td class="lg-w-530"><div class="book-title"><a href="/book/aaa/无id.html">无 id 的坏行</a></div></td>
</tr>
<tr class="dstats-row" data-item_id="42">
  <td class="lg-w-60 hidden-xs">4</td>
  <td class="lg-w-120"><span class="hidden-xs">08.11.2026</span><p>10:00</p></td>
  <td class="lg-w-530"><div class="book-title"><a href="/book/bbb/空标题.html">  </a></div></td>
</tr>
<tr class="dstats-row" data-item_id="43">
  <td class="lg-w-60 hidden-xs">5</td>
  <td class="lg-w-120"><span class="hidden-xs">07.11.2026</span></td>
  <td class="lg-w-530"><div class="book-title"><a href="/book/ccc/无时间.html">缺时间戳的行</a></div></td>
</tr>
</tbody>
</table></body></html>
''';

void main() {
  test('解析 dstats 行：id / 标题 / 短hash / 下载时间', () {
    final books = parseDownloadStatsPage(_pageHtml);

    // 坏行（无 id、空标题）被跳过，缺时间戳的行保留。
    expect(books.length, 3);

    expect(books[0].id, 23787383);
    expect(books[0].title, '男人就愛吃這套！讓他銷魂飛天的52招口愛技巧');
    // 绝对链接也提取短 hash。
    expect(books[0].hash, 'eOWaxzXxjb');
    expect(
      books[0].downloadedAt,
      DateTime(2026, 11, 11, 21, 2),
    );

    expect(books[1].id, 30325900);
    expect(books[1].title, '中国民俗游 民间风俗自助游完全手册 （上册）');
    // 相对链接同样提取。
    expect(books[1].hash, '0OZdLaWajd');
    expect(books[1].downloadedAt, DateTime(2026, 11, 10, 16, 45));

    expect(books[2].id, 43);
    expect(books[2].title, '缺时间戳的行');
    expect(books[2].hash, 'ccc');
    expect(books[2].downloadedAt, isNull);
  });

  test('空页 / 被墙页：0 行返回空列表，不抛异常', () {
    expect(parseDownloadStatsPage('<html><body></body></html>'), isEmpty);
    // 别的页面的行类名不会误匹配。
    expect(
      parseDownloadStatsPage(
        '<table><tr class="booklists-row" data-item_id="1">'
        '<td><a href="/book/hash/x.html">标题</a></td></tr></table>',
      ),
      isEmpty,
    );
  });

  test('repository 解析守卫：非 dstats 文档返回 null，不当成空历史', () async {
    final repo = DownloadStatsRepository(ZLibraryApi());
    // solver 落在登录页/别的页面：没有 dstats 标记 → null（调用方保留
    // 原始墙错误）。
    expect(
      await repo.parsePage(
        '<html><body><form class="login-form"></form></body></html>',
      ),
      isNull,
    );
    // 真 dstats 页但 0 行（空历史）：空列表，是合法结果。
    expect(
      await repo.parsePage(
        '<html><body><div class="dstats-content">'
        '<form class="dstats-form"></form></div></body></html>',
      ),
      isEmpty,
    );
    // 带记录的正常页。
    expect((await repo.parsePage(_pageHtml))!.length, 3);
  });
}
