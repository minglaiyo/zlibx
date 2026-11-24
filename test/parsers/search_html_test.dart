import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

/// Book search results page, SYNTHETIC throughout (invented titles,
/// authors, hashes, ids and tokens — no real user data). The card
/// shape and attribute set mirror the 2026-11-24 capture of
/// `/s/{query}` (bookroom.lifestyle, 51 cards, logged-in session):
/// `#searchResultBox` > `.book-item` > `z-bookcard` with `id`,
/// `isbn`, `termshash`, `href`, `download`, `deleted`, `publisher`,
/// `language`, `year`, `extension`, `filesize`, `rating`, `quality`,
/// `user_token`, `contentTypeParam`, an `<img data-src>` cover and
/// the `slot="title"` / `slot="author"` children.
const _resultsHtml = '''
<html><body>
<form id="searchForm" action="/s/">
  <input type="text" maxlength="200" name="q" id="searchFieldx" value="synthetic query">
</form>
<div id="searchModeTabs">
  <ul>
    <li class="active">书籍&nbsp;(150+)</li>
    <li>文章&nbsp;(3)</li>
  </ul>
</div>
<div id="searchResultBox">
  <div class="book-item resItemBoxBooks ">
    <div class="counter">1</div>
    <z-bookcard id="70001" isbn="9781111111111" termshash="aaaa1111bbbb2222cccc3333dddd4444" href="/book/AbCdEfGh12/Synthetic-Book-One.html" download="/dl/FAKE001" deleted="0" publisher="Synthetic Press One" language="中文" year="2008" extension="epub" filesize="2.48 MB" rating="5.0" quality="5" user_token="<redacted>" contentTypeParam="" class="ready">
      <img data-src="https://example.com/covers100/fake-cover-1.png">
      <div slot="title">Synthetic Book One</div>
      <div slot="author">Test Author Alpha</div>
    </z-bookcard>
  </div>
  <z-promotion book="" async="" id="null" class="ready" demo=""></z-promotion>
  <div class="book-item resItemBoxBooks">
    <div class="counter">2</div>
    <z-bookcard id="70002" isbn="111111111X" termshash="eeee5555ffff6666aaaa7777bbbb8888" href="/book/WxYz0987Ab/Synthetic-Book-Two.html" download="/dl/FAKE002" deleted="0" publisher="Synthetic Press Two" language="english" year="2014" extension="pdf" filesize="7.11 MB" rating="4.9" quality="4" user_token="<redacted>" contentTypeParam="" class="ready">
      <img data-src="">
      <div slot="title">Synthetic Book Two</div>
      <div slot="author">Test Author Beta</div>
    </z-bookcard>
  </div>
  <div class="book-item resItemBoxBooks ">
    <div class="counter">3</div>
    <z-bookcard id="70003" isbn="" termshash="1234abcd5678efgh9012ijkl3456mnop" href="/book/MnOp3456Qr/Synthetic-Copyright-Book-Three.html" download="" deleted="1" publisher="Synthetic Press Three" language="" year="" extension="fb2" filesize="0.50 MB" rating="3.0" quality="1" user_token="<redacted>" contentTypeParam="" class="ready">
      <img data-src="/covers100/fake-relative-cover-3.png">
      <div slot="title">Synthetic Copyright Book Three</div>
      <div slot="author">Test Author Gamma</div>
    </z-bookcard>
  </div>
  <div class="book-item resItemBoxBooks" hidden aria-hidden="true">
    <div class="counter">0</div>
    <z-bookcard id="79999" isbn="" href="/book/FitTemplate00/synthetic-query-text.html" download="" deleted="0" class="fit ready">
      <div slot="title">synthetic query text</div>
      <div slot="author">synthetic query text</div>
    </z-bookcard>
  </div>
</div>
<script>
  var pagerOptions = {
    pagesTotal: 3,
    pagesSpan: 10,
    pageCurrent: 1,
    baseUrl: '/s/synthetic%20query?page=%number%'
  };
</script>
</body></html>
''';

/// A page with no tab count, no pager and no `q` echo: totals stay
/// unknown rather than being invented from the card count.
const _bareHtml = '''
<html><body>
<div id="searchResultBox">
  <div class="book-item resItemBoxBooks ">
    <div class="counter">1</div>
    <z-bookcard id="70004" isbn="" termshash="ffff0000eeee1111" href="/book/BareHash0001/Bare-Synthetic-Book.html" download="/dl/FAKE003" deleted="0" extension="epub" filesize="1.00 MB" class="ready">
      <img data-src="https://example.com/covers100/fake-cover-4.png">
      <div slot="title">Bare Synthetic Book</div>
      <div slot="author">Test Author Delta</div>
    </z-bookcard>
  </div>
</div>
</body></html>
''';

/// The empty-results shape: the box renders, no card does. This is a
/// successful search that found nothing, not a parse failure.
const _noResultsHtml = '''
<html><body>
<form id="searchForm" action="/s/">
  <input type="text" name="q" value="synthetic query">
</form>
<div id="searchModeTabs"><li class="active">书籍&nbsp;(0)</li></div>
<div id="searchResultBox"><div class="noResults">nothing</div></div>
</body></html>
''';

/// The fit template card WITHOUT a `.book-item` wrapper (the shape
/// the whole-document fallback sees): recognised by its empty
/// `termshash` plus the `fit` class.
const _unwrappedFitHtml = '''
<html><body>
<z-bookcard id="79998" class="fit ready" href="/book/FitNoWrap00/synthetic.html">
  <div slot="title">synthetic</div>
</z-bookcard>
<z-bookcard id="70005" termshash="abcd1234" href="/book/RealHash0001/Real-Synthetic-Book.html" download="/dl/FAKE004" deleted="9">
  <div slot="title">Real Synthetic Book</div>
</z-bookcard>
</body></html>
''';

/// A page whose tab carries the English label (non-zh mirror).
const _englishTabHtml = '''
<html><body>
<div id="searchModeTabs"><li class="active">Books&nbsp;(12)</li></div>
<div id="searchResultBox"></div>
</body></html>
''';

void main() {
  group('parseSearchBooksPage', () {
    test('parses cards and skips the hidden fit template and the ad slot', () {
      final page = parseSearchBooksPage(_resultsHtml);
      expect(page.books, hasLength(3));
      expect(page.books.map((b) => b.id), [70001, 70002, 70003]);
    });

    test('maps the card attributes onto Book', () {
      final book = parseSearchBooksPage(_resultsHtml).books.first;
      expect(book.title, 'Synthetic Book One');
      expect(book.author, 'Test Author Alpha');
      expect(book.publisher, 'Synthetic Press One');
      expect(book.language, '中文');
      expect(book.year, 2008);
      expect(book.extension, 'epub');
      expect(book.interestScore, '5.0');
      // The card's filesize is already a display string: it fills
      // filesizeString and never the raw byte count.
      expect(book.filesizeString, '2.48 MB');
      expect(book.filesize, isNull);
      expect(book.href, '/book/AbCdEfGh12/Synthetic-Book-One.html');
      // The webpage's 10-char short hash, never an eapi hash.
      expect(book.hash, 'AbCdEfGh12');
      expect(book.hash, hasLength(10));
    });

    test('keeps the /dl/ link the card carries', () {
      final page = parseSearchBooksPage(_resultsHtml);
      expect(page.books[0].downloadPath, '/dl/FAKE001');
      expect(page.books[1].downloadPath, '/dl/FAKE002');
      // A removed card carries an empty download attribute: null,
      // not an empty string that would build a broken URL.
      expect(page.books[2].downloadPath, isNull);
    });

    test('does not map the card quality onto ratingQuality', () {
      // ratingQuality documents the detail page's rendered decimal;
      // the card's 0-5 integer is a different shape and the detail
      // page fills it when it loads.
      expect(parseSearchBooksPage(_resultsHtml).books.first.ratingQuality,
          isNull);
    });

    test('splits the isbn attribute by length', () {
      final page = parseSearchBooksPage(_resultsHtml);
      expect(page.books[0].isbn13, '9781111111111');
      expect(page.books[0].isbn10, isNull);
      expect(page.books[1].isbn10, '111111111X');
      expect(page.books[1].isbn13, isNull);
      expect(page.books[2].isbn13, isNull);
      expect(page.books[2].isbn10, isNull);
    });

    test('resolves cover and download against baseUrl', () {
      final page = parseSearchBooksPage(
        _resultsHtml,
        baseUrl: 'https://mirror.example',
      );
      expect(page.books[0].downloadPath, 'https://mirror.example/dl/FAKE001');
      expect(page.books[0].cover, 'https://example.com/covers100/fake-cover-1.png');
      // A relative cover becomes absolute; an empty one stays null.
      expect(page.books[2].cover,
          'https://mirror.example/covers100/fake-relative-cover-3.png');
      expect(page.books[1].cover, isNull);
    });

    test('records why a removed card is unavailable and keeps it listed', () {
      final page = parseSearchBooksPage(_resultsHtml);
      expect(page.books.any((b) => b.id == 70003), isTrue);
      expect(page.unavailableReasons, {70003: 'copyright'});
      expect(parseSearchBooksPage(_resultsHtml).books[2].title,
          'Synthetic Copyright Book Three');
    });

    test('reads the pager count and the tab total', () {
      final page = parseSearchBooksPage(_resultsHtml);
      expect(page.totalPages, 3);
      // `书籍 (150+)` is a bucket: the digits, not the plus.
      expect(page.total, 150);
    });

    test('leaves both totals unknown on a bare page', () {
      final page = parseSearchBooksPage(_bareHtml);
      expect(page.totalPages, isNull);
      expect(page.total, isNull);
      expect(page.books.single.downloadPath, '/dl/FAKE003');
      expect(page.books.single.year, isNull);
    });

    test('parses an empty result set as a successful search', () {
      final page = parseSearchBooksPage(_noResultsHtml);
      expect(page.books, isEmpty);
      expect(page.unavailableReasons, isEmpty);
      expect(page.total, 0);
    });

    test('skips an unwrapped fit template and maps deleted 9', () {
      final page = parseSearchBooksPage(_unwrappedFitHtml);
      expect(page.books.map((b) => b.id), [70005]);
      expect(page.unavailableReasons, {70005: 'removed'});
    });

    test('reads the English tab label', () {
      expect(parseSearchBooksPage(_englishTabHtml).total, 12);
    });

    test('never reads user_token or termshash into the book', () {
      // Both are user- or eapi-scoped values that must not reach the
      // model (the same rule every other card parser follows).
      final book = parseSearchBooksPage(_resultsHtml).books.first;
      final json = book.toJson();
      expect(json.values.any((v) => '$v'.contains('redacted')), isFalse);
      expect(json.values.any((v) => '$v'.contains('aaaa1111')), isFalse);
    });
  });

  group('extractSearchBooksQuery', () {
    test('returns the query the form echoes back', () {
      expect(extractSearchBooksQuery(_resultsHtml), 'synthetic query');
    });

    test('returns null when the page carries no q value', () {
      expect(extractSearchBooksQuery(_bareHtml), isNull);
      expect(extractSearchBooksQuery('<html><body></body></html>'), isNull);
      expect(
        extractSearchBooksQuery(
          '<input type="text" name="q" value="">',
        ),
        isNull,
      );
    });
  });

  group('parseSearchBooksPageH', () {
    test('uses the Dart parser when no hook is injected', () async {
      final viaHook = await parseSearchBooksPageH(_resultsHtml);
      // Book has no value equality, so compare the fields the hook
      // path must reproduce exactly.
      expect(
        viaHook.books.map((b) => [b.id, b.title, b.hash, b.downloadPath]),
        parseSearchBooksPage(_resultsHtml)
            .books
            .map((b) => [b.id, b.title, b.hash, b.downloadPath]),
      );
    });

    test('prefers the injected parse hook', () async {
      var called = 0;
      searchBooksParseOverride = (html, baseUrl) async {
        called++;
        return const BookSearchPage(books: []);
      };
      try {
        final page = await parseSearchBooksPageH(
          _resultsHtml,
          baseUrl: 'https://mirror.example',
        );
        expect(called, 1);
        expect(page.books, isEmpty);
      } finally {
        searchBooksParseOverride = null;
      }
      // Restored: the Dart path answers again (the hook is a global,
      // so leaking it would change every later test).
      expect((await parseSearchBooksPageH(_resultsHtml)).books, hasLength(3));
    });
  });
}
