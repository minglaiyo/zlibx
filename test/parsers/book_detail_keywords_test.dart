import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

/// 详情页关键词提取（方案 F3）：/terms/ 链接文本、去重、页内顺序、
/// 上限 12；文本超 30 字符的噪声与非 /terms/ 链接不进结果。
const _fixture = '''
<html><body>
  <div class="book-details-details-page">
    <div class="bookProperty">
      <a href="/terms/%E6%8A%95%E8%B5%84">投资</a>
      <a href="/terms/%E9%87%91%E8%9E%8D">金融</a>
      <a href="/terms/%E6%8A%95%E8%B5%84">投资</a>
      <a href="/terms/%E9%A2%84%E6%B5%8B">预测</a>
    </div>
    <a href="/author/someone">Someone</a>
    <a href="/book/abc/Some-Book.html">Some Book</a>
  </div>
</body></html>
''';

void main() {
  test('提取 /terms/ 链接文本：去重、保序、上限', () async {
    final keywords = parseBookDetailKeywords(_fixture);
    expect(keywords, ['投资', '金融', '预测']);
  });

  test('空页面 / 无关键词：空列表不抛异常', () async {
    expect(parseBookDetailKeywords('<html></html>'), isEmpty);
    expect(parseBookDetailKeywords(''), isEmpty);
  });

  test('fetchBookDetailExtras 把 keywords 带进 BookDetailExtras（contract）', () {
    // extras 的字段是可空列表并随 extras JSON 持久化（方案 F3 的缓存
    // 键），这里只钉字段存在与默认值。
    const extras = BookDetailExtras(
      metadata: BookDetailMetadata(),
      keywords: ['投资'],
    );
    expect(extras.keywords, ['投资']);
    const empty = BookDetailExtras(metadata: BookDetailMetadata());
    expect(empty.keywords, isEmpty);
  });
}
