import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

/// `/categories` 目录页解析（方案 F1）：裸 `/category/{id}` 开新组，
/// `/category/{id}/{slug}` 挂最近一组，"(N)" 计数剥出来。
const _fixture = '''
<html><body>
  <nav><a href="/categories">种类</a><a href="/category/999/Breadcrumb-Noise">面包屑杂项</a></nav>
  <h3><a href="/category/1">Arts</a></h3>
  <a href="/category/40/Architecture">Architecture (23282)</a>
  <a href="/category/49/Business-of-Art">Business of Art (728)</a>
  <h3><a href="/category/2">Computers</a></h3>
  <a href="/category/60/Programming">Programming (32109)</a>
</body></html>
''';

void main() {
  test('裸链接开组、子级挂最近一组、计数剥离', () async {
    final page = await parseCategoriesDirectoryH(_fixture);

    expect(page.groups, hasLength(2));

    final arts = page.groups[0];
    expect(arts.parent.id, 1);
    expect(arts.parent.name, 'Arts');
    expect(arts.parent.slug, isNull);
    expect(arts.children, hasLength(2));
    expect(arts.children[0].id, 40);
    expect(arts.children[0].slug, 'Architecture');
    expect(arts.children[0].name, 'Architecture');
    expect(arts.children[0].count, 23282);
    expect(arts.children[1].count, 728);

    final computers = page.groups[1];
    expect(computers.parent.id, 2);
    expect(computers.children.single.id, 60);
    expect(computers.children.single.count, 32109);
  });

  test('面包屑杂项（首组之前的子级链接）被丢弃', () async {
    final page = await parseCategoriesDirectoryH(_fixture);
    // /category/999/Breadcrumb-Noise 出现在任何父级之前 → 不进树。
    final allIds = page.groups.expand((g) => g.children).map((c) => c.id);
    expect(allIds, isNot(contains(999)));
  });

  test('同一父链接重复出现不重复开组', () async {
    const sticky = '''
<html><body>
  <h3><a href="/category/1">Arts</a></h3>
  <a href="/category/1">Arts</a>
  <a href="/category/40/Architecture">Architecture (23282)</a>
</body></html>
''';
    final page = await parseCategoriesDirectoryH(sticky);
    expect(page.groups, hasLength(1));
    expect(page.groups.single.children, hasLength(1));
  });

  test('空/畸形输入不抛异常', () async {
    final empty = await parseCategoriesDirectoryH('<html><body></body></html>');
    expect(empty.groups, isEmpty);
    final broken = await parseCategoriesDirectoryH('not html at all');
    expect(broken.groups, isEmpty);
  });
}
