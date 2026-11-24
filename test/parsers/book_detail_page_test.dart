import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

/// Detail-page → [Book] parsers, modelled on the live capture of
/// `/book/Ej8q7Dmrv9/三体.html` (zh.z-library.sk, 2026-11-24, 214 KB).
///
/// The capture's real shapes, all reproduced in the fixtures below:
///  * three `application/ld+json` blocks (`WebSite`, `Book`,
///    `BreadcrumbList`) — the `@type` test is load-bearing;
///  * the JSON-LD `Book` carries `datePublished: 2008` (a number),
///    `inLanguage: {"@type":"Language","name":"chinese"}`,
///    `publisher: {"@type":"Organization","name":…}`, `isbn`, and
///    `numberOfPages: 0` for "unknown";
///  * its `author[0].name` arrives with LITERAL braces (`{刘慈欣}`) and
///    its `description` with double-escaped markup (`&lt;p&gt;`) — the
///    DOM is the trusted source for both;
///  * the property rows use single-quoted attributes
///    (`class='bookProperty property_year'`) and the language value is
///    a `span`, not a `div`;
///  * `property_isbn 10` / `property_isbn 13` put the number in its own
///    class token, so those two rows only resolve through the
///    label-matching half of [parseBookDetailProperties];
///  * three `/dl/…` anchors exist — one visible button and two hidden
///    `<template>` duplicates; only the button is the user's address.
///
/// Shape verified against two real captures. The first (三体 /
/// 26610712 / Ej8q7Dmrv9) drove the rows; the button markup and its
/// **absolute** href come from the 2026-11-24 capture of 给仰望者的星空史
/// (26018814), where the page renders
/// `href="https://zh.z-library.sk/dl/EwAD8KXkBL"` — not `/dl/…`.
/// That capture also fixes the decoy: the 在线阅读 button is
/// `a.dlButton.reader-link` and appears **before** the download button.
const _site = 'https://zh.z-library.sk';
const _href = '/book/Ej8q7Dmrv9/三体.html';

/// A page in the shape the capture has: JSON-LD + rows + buttons.
String _page({
  // One JSON object per script tag — the capture has three separate
  // `application/ld+json` blocks (WebSite, Book, BreadcrumbList), and
  // two objects inside one tag is not parseable JSON.
  List<String> ld = const [
    '{"@context":"https://schema.org","@type":"WebSite","name":"Z-Library"}',
    '{"@context":"https://schema.org","@type":"Book","name":"{三体}",'
        '"author":[{"@type":"Person","name":"{刘慈欣}"}],'
        '"publisher":{"@type":"Organization","name":"{重庆出版社}"},'
        '"image":"https://cdn.example/covers300/a.jpg",'
        '"isbn":"9787229042066","numberOfPages":0,"datePublished":2008,'
        '"inLanguage":{"@type":"Language","name":"chinese"}}',
  ],
  String title = '<h1 class="book-title" itemprop="name">三体</h1>',
  String authors =
      '<i class="authors"><a href="/author/%E5%88%98%E6%85%88%E6%AC%A3">刘慈欣</a></i>',
  String description =
      '<div id="bookDescriptionBox">第一段<br>第二段<p>第三段</p></div>',
  String rows =
      "<div class='bookProperty property_year'><div class='property_label'>出版年:</div><div class='property_value'>2008</div></div>"
      "<div class='bookProperty property_publisher'><div class='property_label'>出版者:</div><div class='property_value'>重庆出版社</div></div>"
      "<div class='bookProperty property_language'><div class='property_label'>语言:</div><span class='property_value text-capitalize'>中文</span></div>"
      "<div class='bookProperty property_file'><div class='property_label'>文件:</div><div class='property_value'>EPUB, 2.48 MB</div></div>"
      "<div class='bookProperty property_isbn 13'><div class='property_label'>ISBN 13:</div><div class='property_value'>9787229042066</div></div>"
      "<div class='bookProperty property_categories'><div class='property_label'>分类:</div><div class='property_value'><a href='/category/166/x'>Science Fiction</a></div></div>",
  String dlButton =
      '<a class="btn btn-default dlButton addDownloadedBook" '
      'href="$_site/dl/ABVGVr08wz" data-book_id="26610712" '
      'data-isbn="9787229042066" rel="nofollow">'
      '<i class="zlibicon-bookcard-download"></i>'
      '<span class="book-property__extension">epub</span>, 2.48 MB</a>',
  String masonry = '',
  // 在线阅读那颗也是 `a.dlButton`，真页面上它排在下载之前，href 里只以
  // 百分号编码带着 `download_location=…%2Fdl%2F…`。
  String readerButton =
      '<a class="btn btn-primary dlButton reader-link" '
      'href="https://reader.z-library.sk/read/80eb6002d082c1c9/book/'
      'Ej8q7Dmrv9/%E4%B8%89%E4%BD%93.html?client_key=1fFLi67gBrNRP1j1'
      '&extension=epub&download_location='
      'https%3A%2F%2Fzh.z-library.sk%2Fdl%2FABVGVr08wz">在线阅读</a>',
}) =>
    '<html><head>'
    '${ld.map((b) => '<script type="application/ld+json">$b</script>').join()}'
    '</head>'
    '<body>$title$authors$description'
    '<div class="bookDetailsBox">$rows</div>'
    '<template><a href="/dl/HIDDEN1" hidden></a></template>'
    '$readerButton$dlButton$masonry</body></html>';

Book? parse(String html) =>
    parseBookDetailPage(html, baseUrl: _site, href: _href);

void main() {
  group('parseBookDetailPage', () {
    test('a real-shaped page yields the whole book', () {
      final book = parse(_page());
      expect(book, isNotNull);
      expect(book!.id, 26610712);
      expect(book.title, '三体');
      expect(book.author, '刘慈欣');
      expect(book.publisher, '重庆出版社');
      expect(book.year, 2008);
      expect(book.extension, 'epub');
      expect(book.filesizeString, '2.48 MB');
      expect(book.categories, 'Science Fiction');
      expect(book.isbn13, '9787229042066');
      expect(book.cover, 'https://cdn.example/covers300/a.jpg');
      expect(book.downloadPath, '$_site/dl/ABVGVr08wz');
      expect(book.href, _href);
      expect(book.hash, 'Ej8q7Dmrv9');
    });

    test('hash comes from the fetched href, never from the page', () {
      // The page links to other books too (recommendations), so a
      // scraped /book/… could describe a different one.
      final book = parseBookDetailPage(
        _page(masonry: _recommendation),
        baseUrl: _site,
        href: _href,
      );
      expect(book!.hash, 'Ej8q7Dmrv9');
      expect(book.href, _href);
    });

    test('language takes the JSON-LD machine value, not the row', () {
      // The row renders 中文 for the zh mirror; the app compares the
      // field against filter values (`chinese`), which is what the
      // search cards carry too.
      expect(parse(_page())!.language, 'chinese');
      // …and falls back to the row when the block omits it.
      final noLd = parse(
        _page(ld: ['{"@context":"https://schema.org","@type":"WebSite"}']),
      );
      expect(noLd!.language, '中文');
    });

    test('author takes the DOM, not the brace-wrapped JSON-LD', () {
      final book = parse(_page(authors: ''));
      // No DOM to fall back on: the braces are stripped, not kept.
      expect(book!.author, '刘慈欣');
      expect(parse(_page())!.author, '刘慈欣');
      expect(parse(_page())!.publisher, '重庆出版社');
    });

    test('multiple authors join the way the page renders them', () {
      final book = parse(
        _page(
          ld: [
            '{"@type":"Book","author":['
            '{"@type":"Person","name":"甲"},{"@type":"Person","name":"乙"}]}',
          ],
          authors: '<i class="authors">甲, 乙</i>',
        ),
      );
      expect(book!.author, '甲, 乙');
      final domless = parse(
        _page(
          authors: '',
          ld: [
            '{"@type":"Book","author":['
            '{"@type":"Person","name":"甲"},{"@type":"Person","name":"乙"}]}',
          ],
        ),
      );
      expect(domless!.author, '甲, 乙');
    });

    test('description keeps its paragraphs', () {
      expect(parse(_page())!.description, '第一段\n第二段\n第三段');
    });

    test('description falls back to the JSON-LD, entities released', () {
      final book = parse(
        _page(
          description: '',
          ld: ['{"@type":"Book","description":"前段&lt;p&gt;后段&lt;/p&gt;尾段"}'],
        ),
      );
      expect(book!.description, '前段\n后段\n尾段');
    });

    test('numberOfPages 0 is unknown, not a page count', () {
      expect(parse(_page())!.pages, isNull);
      expect(
        parse(_page(ld: ['{"@type":"Book","numberOfPages":612}']))!.pages,
        612,
      );
    });

    test('datePublished may be a full date', () {
      expect(
        parse(
          _page(
            rows:
                "<div class='bookProperty property_year'>"
                "<div class='property_label'>年:</div>"
                "<div class='property_value'>没有</div></div>",
            ld: ['{"@type":"Book","datePublished":"2008-11-01"}'],
          ),
        )!.year,
        2008,
      );
    });

    test('isbn10 comes from the spaced class row', () {
      // `class="bookProperty property_isbn 10"` — the number is its own
      // class token, so only the label half of the metadata parser can
      // find it.
      final book = parse(
        _page(
          rows:
              "<div class='bookProperty property_isbn 10'>"
              "<div class='property_label'>ISBN 10:</div>"
              "<div class='property_value'>7229042062</div></div>"
              "<div class='bookProperty property_isbn 13'>"
              "<div class='property_label'>ISBN 13:</div>"
              "<div class='property_value'>9787229042066</div></div>",
        ),
      );
      expect(book!.isbn10, '7229042062');
      expect(book.isbn13, '9787229042066');
    });

    test('a single JSON-LD isbn lands on the right ISBN field', () {
      expect(
        parse(
          _page(ld: ['{"@type":"Book","isbn":"9787229042066"}'], rows: ''),
        )!.isbn13,
        '9787229042066',
      );
      expect(
        parse(
          _page(ld: ['{"@type":"Book","isbn":"7229042062"}'], rows: ''),
        )!.isbn10,
        '7229042062',
      );
    });

    test('file row absent: the download button label fills it', () {
      final book = parse(
        _page(
          rows: '',
          dlButton:
              '<a class="btn btn-default dlButton addDownloadedBook" '
              'href="/dl/ABVGVr08wz" data-book_id="26610712">'
              'epub, 2.48 MB</a>',
          ld: ['{"@type":"Book"}'],
        ),
      );
      expect(book!.extension, 'epub');
      expect(book.filesizeString, '2.48 MB');
    });

    test('the hidden template download link is never used', () {
      final book = parse(
        _page(
          rows: '',
          ld: ['{"@type":"Book"}'],
          // The page still identifies its book (the capture repeats
          // `data-book_id` across several controls), but the only
          // /dl/ address left is the hidden template clone.
          dlButton: '<span data-book_id="26610712"></span>',
        ),
      );
      expect(book!.id, 26610712);
      expect(book.downloadPath, isNull);
    });

    test('without a baseUrl the site-relative address is kept', () {
      final book = parseBookDetailPage(_page(), href: _href);
      expect(book!.downloadPath, '/dl/ABVGVr08wz');
    });

    test('a site-relative button href still resolves', () {
      // The card shape the search page uses; the detail page writes the
      // absolute form (next test), and both have to work.
      final book = parse(
        _page(
          dlButton:
              '<a class="btn btn-default dlButton addDownloadedBook" '
              'href="/dl/ABVGVr08wz" data-book_id="26610712">epub</a>',
        ),
      );
      expect(book!.downloadPath, '$_site/dl/ABVGVr08wz');
    });

    test('the real page writes an ABSOLUTE button href', () {
      // 2026-11-24 真页面抓包（给仰望者的星空史 / 26018814）里那枚按钮是
      // `href="https://zh.z-library.sk/dl/EwAD8KXkBL"`。此前这一支只认
      // `startsWith('/dl/')`，于是每张真页面都报成"没有下载地址"，
      // 下载停在 `Invalid hash`——这条测试钉住那个回归。
      final book = parse(
        _page(
          rows: '',
          dlButton:
              '<a class="btn btn-default dlButton addDownloadedBook" '
              'href="$_site/dl/EwAD8KXkBL" data-book_id="26018814" '
              'data-isbn="9787521755527" rel="nofollow">'
              '<i class="zlibicon-bookcard-download"></i>'
              '<span class="book-property__extension">pdf</span>, 12.35 MB</a>',
        ),
      );
      expect(book!.id, 26018814);
      expect(book.downloadPath, '$_site/dl/EwAD8KXkBL');
      expect(book.extension, 'pdf');
      expect(book.filesizeString, '12.35 MB');
    });

    test('the button is rebuilt on the fetched page origin, not the host '
        'the page chose to name', () {
      // 墙 cookie 按 host 生效，token 得落在当前镜像自己身上。
      final book = parseBookDetailPage(
        _page(
          rows: '',
          dlButton:
              '<a class="dlButton addDownloadedBook" data-book_id="26610712" '
              'href="https://1lib.sk/dl/OTHERHOST"></a>',
        ),
        baseUrl: 'https://bookroom.lifestyle',
        href: _href,
      );
      expect(book!.downloadPath, 'https://bookroom.lifestyle/dl/OTHERHOST');
    });

    test('the reader button is not the download address', () {
      // `a.btn.btn-primary.dlButton.reader-link` 排在下载按钮之前，href 是
      // reader 主机的 /read/…，只把 /dl/ token 藏在 query 的编码里。
      final book = parse(
        _page(
          rows: '',
          dlButton: '<span data-book_id="26610712"></span>',
        ),
      );
      expect(book, isNotNull);
      expect(book!.downloadPath, isNull);
      // 也不能借它的文字当"文件行"（那会把"在线阅读"报成格式）。
      expect(book.extension, isNull);
      expect(book.filesizeString, isNull);
    });

    test('a non-https button href is refused', () {
      final book = parse(
        _page(
          rows: '',
          dlButton:
              '<a class="dlButton addDownloadedBook" data-book_id="26610712" '
              'href="http://zh.z-library.sk/dl/INSECURE"></a>',
        ),
      );
      expect(book!.downloadPath, isNull);
    });

    test('a button with no /dl/ token is not a download address', () {
      final book = parse(
        _page(
          rows: '',
          dlButton:
              '<a class="dlButton addDownloadedBook" data-book_id="26610712" '
              'href="$_site/book/26610712/Ej8q7Dmrv9/"></a>',
        ),
      );
      expect(book!.downloadPath, isNull);
    });

    test("another book's button on this page is not this book's address", () {
      // 首页/推荐位上的 `/dl/` 带着别人的 token：宁可报 no-link，也不能
      // 把另一本书的文件下过来。
      final book = parse(
        _page(
          rows: '',
          dlButton:
              '<span data-book_id="26610712"></span>'
              '<a class="dlButton addDownloadedBook" data-book_id="99999999" '
              'href="$_site/dl/SOMEOTHER1"></a>',
        ),
      );
      expect(book!.downloadPath, isNull);
    });

    test('a placeholder cover parses to no cover', () {
      final book = parse(
        _page(
          ld: ['{"@type":"Book","image":"https://cdn/i/cover-not-exists.png","isbn":"x"}'],
        ),
      );
      expect(book!.cover, isNull);
    });

    test('no data-book_id is not a book page', () {
      expect(
        parse('<html><body><h1 class="book-title">别的页面</h1></body></html>'),
        isNull,
      );
    });

    test('a book page with no title is not a book page', () {
      expect(
        parse('<html><body><a data-book_id="1">下载</a></body></html>'),
        isNull,
      );
    });

    test('a malformed JSON-LD block is skipped, not thrown', () {
      final book = parse(_page(ld: ['{"@type":"Book", broken']));
      expect(book!.title, '三体');
      expect(book.year, 2008);
    });

    test('a non-Book JSON-LD block is not mistaken for the book', () {
      final book = parse(
        _page(ld: ['{"@type":"WebSite","name":"Z-Library"}'], rows: ''),
      );
      expect(book!.publisher, isNull);
      expect(book.isbn13, isNull);
      expect(book.title, '三体');
    });

    test('the WebSite template never wins the isbn slot', () {
      // Regression guard: picking the first ld+json block instead of
      // the Book one would read a name/url from the site block.
      final book = parse(
        _page(ld: ['{"@type":"Book","isbn":"{9787229042066}"}'], rows: ''),
      );
      expect(book!.isbn13, '9787229042066');
    });

    test('empty html parses to null', () {
      expect(parse(''), isNull);
    });
  });

  group('parseBookDetailRecommendations', () {
    test('reads the z-masonry shelf', () {
      final books = parseBookDetailRecommendations(
        _page(masonry: _recommendation),
        baseUrl: _site,
      );
      expect(books, hasLength(2));
      expect(books[0].id, 102668369);
      expect(books[0].title, '十日终焉');
      expect(books[0].author, '杀虫队队员');
      expect(books[0].hash, '0vpJZoQLRr');
      expect(books[0].cover, 'https://cdn.example/covers200/a.jpg');
    });

    test('drops the dsource tracking marker and keeps a clean path', () {
      final books = parseBookDetailRecommendations(
        _page(masonry: _recommendation),
        baseUrl: _site,
      );
      expect(
        books[0].href,
        '/book/0vpJZoQLRr/%E5%8D%81%E6%97%A5%E7%BB%88%E7%84%89.html',
      );
    });

    test('a placeholder cover is no cover, a missing id is no book', () {
      final books = parseBookDetailRecommendations(
        _page(
          masonry:
              '<z-masonry source="recommend">'
              '<a href="/book/AAAA/one.html"><z-cover id="1" '
              'title="占位封面" author="某人"><img src="/img/cover-not-exists.png">'
              '</z-cover></a>'
              '<a href="/book/BBBB/two.html"><z-cover title="没有 id">'
              '</z-cover></a></z-masonry>',
        ),
        baseUrl: _site,
      );
      expect(books, hasLength(1));
      expect(books.single.cover, isNull);
    });

    test('a page without the shelf is an empty list', () {
      expect(parseBookDetailRecommendations(_page()), isEmpty);
      expect(parseBookDetailRecommendations(''), isEmpty);
    });

    test('falls back to the mosaic wrapper when masonry is absent', () {
      final books = parseBookDetailRecommendations(
        '<div class="books-mosaic"><a href="/book/CCCC/three.html">'
        '<z-cover id="3" title="丙"></z-cover></a></div>',
      );
      expect(books.single.id, 3);
      expect(books.single.hash, 'CCCC');
    });

    test('lazy-loaded covers read from data-src', () {
      final books = parseBookDetailRecommendations(
        _page(
          masonry:
              '<z-masonry source="recommend">'
              '<a href="/book/DDDD/four.html"><z-cover id="4" '
              'title="丁"><img data-src="/covers200/lazy.jpg"></z-cover></a>'
              '</z-masonry>',
        ),
        baseUrl: _site,
      );
      expect(books.single.cover, '$_site/covers200/lazy.jpg');
    });
  });
}

/// Two cards, in the capture's shape: `z-cover` inside a `/book/…`
/// link, one with an isbn, one without.
const _recommendation = '''
<div class="books-mosaic">
  <div class="recommendations"><h2>您可能感兴趣</h2></div>
  <z-masonry source="recommend" columns="5" batch="21">
    <a href="/book/0vpJZoQLRr/%E5%8D%81%E6%97%A5%E7%BB%88%E7%84%89.html?dsource=recommend">
      <z-cover volume id="102668369" isbn="" author="杀虫队队员" title="十日终焉">
        <img src="https://cdn.example/covers200/a.jpg" loading="lazy">
      </z-cover>
    </a>
    <a href="/book/BjnN0bdzj2/quan.html">
      <z-cover id="107072718" isbn="9787539947861" title="三体全集">
        <img src="https://cdn.example/covers200/b.jpg">
      </z-cover>
    </a>
  </z-masonry>
</div>
''';
