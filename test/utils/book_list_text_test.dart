import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/utils/book_list_text.dart';

void main() {
  group('buildBookListText (#101, 排版 D)', () {
    test('标题（N 本）+ 分隔线 + 一本书一行：书名 — 作者 — 年份，缺的省掉', () {
      expect(
        buildBookListText(
          title: '我的书单',
          books: const [
            (title: '红楼梦', author: '曹雪芹', year: '1791'),
            (title: '三体', author: '刘慈欣', year: null),
            (title: '无名书', author: null, year: null),
            (title: '有年份无作者', author: '', year: '2020'),
          ],
        ),
        '我的书单（4 本）\n'
        '─────\n'
        '红楼梦 — 曹雪芹 — 1791\n'
        '三体 — 刘慈欣\n'
        '无名书\n'
        '有年份无作者 — 2020',
      );
    });

    test('z 站书单：链接附在末尾；空书单只有标题+分隔线+链接', () {
      expect(
        buildBookListText(
          title: '科幻',
          books: const [
            (title: '三体', author: '刘慈欣', year: '2008'),
          ],
          link: 'https://1lib.sk/booklists/123/abc',
        ),
        '科幻（1 本）\n'
        '─────\n'
        '三体 — 刘慈欣 — 2008\n'
        'https://1lib.sk/booklists/123/abc',
      );
      expect(
        buildBookListText(
          title: '空书单',
          books: const [],
          link: 'https://1lib.sk/booklists/123/abc',
        ),
        '空书单（0 本）\n─────\nhttps://1lib.sk/booklists/123/abc',
      );
    });

    test('收藏/图书馆：没有链接，就只有标题+分隔线+书', () {
      expect(
        buildBookListText(
          title: '我的图书馆',
          books: const [
            (title: '三体', author: '刘慈欣', year: '2008'),
          ],
        ),
        '我的图书馆（1 本）\n─────\n三体 — 刘慈欣 — 2008',
      );
    });
  });
}
