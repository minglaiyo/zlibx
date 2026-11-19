import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

/// Related-booklists block ("关联书单"), SYNTHETIC throughout (invented
/// cover authors/titles — no real user data): 4 cards mirroring the
/// 超速学习 capture 2026-11-12 (zh.z-library.sk) — the first card
/// carries `topic="1"` (a bare number IS the display name there),
/// the others word topics with URL-encoded slugs in the href; covers
/// stack inside each card as `<z-cover>` children. The fourth card
/// mirrors the capture too (`quantity="280"`, covers present —
/// verified against the real page, not 4 / coverless). The coverless
/// shape is tested separately below with its own snippet, since no
/// card in the capture is coverless. One extra z-booklist sits
/// OUTSIDE the block and must be ignored.
const _detailHtml = '''
<html><body>
<div class="related-booklists-block">
  <h2 class="color1">关联书单</h2>
  <div class="z-booklists-carousel" data-book_id="21050993" data-loader="loadBooklists" data-booklists_type="related">
    <z-carousel wings-color="var(--related-booklist-wings--rgb)" class="ready">
      <z-booklist tile="" style="width: 144px;" href="/booklist/498889/f77552/1.html" id="498889" topic="1" quantity="32" class="ready">
        <z-cover id="5748099" author="Synthetic Author One" title="Synthetic Book One" class="ready" priority="true"><img data-src="https://example.com/covers200/fake-cover-1.jpg"></z-cover>
        <z-cover id="18071702" author="Synthetic Author Two" title="Synthetic Book Two" class="ready"><img data-src="https://example.com/covers200/fake-cover-2.jpg"></z-cover>
      </z-booklist>
      <z-booklist tile="" style="width: 144px;" href="/booklist/4007439/2c889e/%E5%AD%A6%E4%B9%A0.html" id="4007439" topic="学习" quantity="21" class="ready">
        <z-cover id="23630137" author="Synthetic Author Three" title="Synthetic Book Three" class="ready"><img data-src="/covers200/fake-relative-3.jpg"></z-cover>
      </z-booklist>
      <z-booklist tile="" style="width: 144px;" href="/booklist/3023620/a45006/%E6%9C%AA%E4%B8%8B%E8%BD%BD2.html" id="3023620" topic="未下载2" quantity="980" class="ready">
        <z-cover id="80001" author="Synthetic Author Four" title="Synthetic Book Four" class="ready"><img data-src="https://example.com/covers200/fake-cover-4.png"></z-cover>
      </z-booklist>
      <z-booklist tile="" style="width: 144px;" href="/booklist/691722/0600be/synthetic-topic.html" id="691722" topic="学习科学与教育" quantity="280" class="ready">
        <z-cover id="16864591" author="Synthetic Author Five" title="Synthetic Book Five" class="ready" priority="true"><img data-src="https://example.com/covers200/fake-cover-5.jpg"></z-cover>
        <z-cover id="19189006" author="Synthetic Author Six" title="Synthetic Book Six" class="ready"><img data-src="https://example.com/covers200/fake-cover-6.jpg"></z-cover>
      </z-booklist>
    </z-carousel>
  </div>
</div>
<z-booklist href="/booklist/111111/aaaaaa/outside.html" id="111111" topic="outside card" quantity="1" class="ready"></z-booklist>
</body></html>
''';

void main() {
  group('parseRelatedBooklists', () {
    test('parses every card in the block, ignores cards outside it', () {
      final lists = parseRelatedBooklists(
        _detailHtml,
        baseUrl: 'https://zh.z-library.sk',
      );
      expect(lists, hasLength(4));
      expect(lists.map((l) => l.id), [
        '498889',
        '4007439',
        '3023620',
        '691722',
      ]);
    });

    test('maps topic to name and quantity to count, verbatim', () {
      final lists = parseRelatedBooklists(
        _detailHtml,
        baseUrl: 'https://zh.z-library.sk',
      );
      // A bare number is the card's display name on the site too.
      expect(lists[0].name, '1');
      expect(lists[0].count, 32);
      expect(lists[1].name, '学习');
      expect(lists[1].count, 21);
      expect(lists[2].name, '未下载2');
      expect(lists[2].count, 980);
      expect(lists[3].name, '学习科学与教育');
      expect(lists[3].count, 280);
    });

    test('resolves list URLs against the site base', () {
      final lists = parseRelatedBooklists(
        _detailHtml,
        baseUrl: 'https://zh.z-library.sk',
      );
      expect(
        lists[0].url,
        'https://zh.z-library.sk/booklist/498889/f77552/1.html',
      );
      expect(
        lists[1].url,
        'https://zh.z-library.sk/booklist/4007439/2c889e/%E5%AD%A6%E4%B9%A0.html',
      );
    });

    test('preview books come from the stacked z-cover children', () {
      final lists = parseRelatedBooklists(
        _detailHtml,
        baseUrl: 'https://zh.z-library.sk',
      );
      expect(lists[0].previewBooks, hasLength(2));
      expect(lists[0].previewBooks[0].id, 5748099);
      expect(lists[0].previewBooks[0].title, 'Synthetic Book One');
      expect(lists[0].previewBooks[0].author, 'Synthetic Author One');
      expect(
        lists[0].previewBooks[0].cover,
        'https://example.com/covers200/fake-cover-1.jpg',
      );
      // The related block wraps covers in no book link, so the hash
      // stays null (display-only previews).
      expect(lists[0].previewBooks[0].hash, isNull);
      expect(
        lists[0].coverUrl,
        'https://example.com/covers200/fake-cover-1.jpg',
      );
      // Relative cover resolves against the base.
      expect(
        lists[1].previewBooks[0].cover,
        'https://zh.z-library.sk/covers200/fake-relative-3.jpg',
      );
      // The fourth card mirrors the capture too: covers present.
      expect(lists[3].previewBooks, hasLength(2));
      expect(lists[3].previewBooks[0].id, 16864591);
      expect(lists[3].previewBooks[0].title, 'Synthetic Book Five');
      expect(
        lists[3].coverUrl,
        'https://example.com/covers200/fake-cover-5.jpg',
      );
    });

    test('a card without covers still parses (no preview books)', () {
      // Standalone snippet: no card in the capture is coverless, so
      // this shape is tested on its own instead of faking card 4.
      const html = '''
<html><body>
<div class="related-booklists-block">
  <div class="z-booklists-carousel">
    <z-booklist tile="" href="/booklist/691722/0600be/synthetic-topic.html" id="691722" topic="学习科学与教育" quantity="280" class="ready">
    </z-booklist>
  </div>
</div>
</body></html>
''';
      final lists = parseRelatedBooklists(
        html,
        baseUrl: 'https://zh.z-library.sk',
      );
      expect(lists, hasLength(1));
      expect(lists[0].name, '学习科学与教育');
      expect(lists[0].count, 280);
      expect(lists[0].previewBooks, isEmpty);
      expect(lists[0].coverUrl, isEmpty);
    });

    test('a page without the block parses to an empty list', () {
      const html =
          '<html><body><div class="bookDetailsBox"></div></body></html>';
      final lists = parseRelatedBooklists(
        html,
        baseUrl: 'https://zh.z-library.sk',
      );
      expect(lists, isEmpty);
    });
  });
}
