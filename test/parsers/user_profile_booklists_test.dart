import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

const _baseUrl = 'https://zh.z-library.sk';

/// Minimal profile page modelled on the live HTML captured 2026-11-07
/// (another user's `/profile/{id}/{hash}` document): one document
/// carries every tab — plans, comments, booklists — and the booklists
/// tab holds full `<z-booklist>` elements with preview covers.
const _profileHtml = '''
<html><body>
<div z-tab="plans"></div>
<div z-tab="comments">
<z-comments total="1" type="user" id="21490583" username="someone" avatar="" lang="zh" sorting="asc"></z-comments>
</div>
<div z-tab="booklists">
<div class="booklists-list">
<z-booklist id="2690671" href="/booklist/2690671/2ac488/math-list.html" topic="数学书单" author="someone" authorProfile="/booklists/user/21490583" authorAvatar="" quantity="15" views="29" comments="0" description="" color="0">
<a href="/book/abcdef123456/slug-one.html"><z-cover id="1045682" author="Author One" title="第一本书"><img data-src="https://cdn.example.com/1.jpg"></z-cover></a>
<a href="/book/9876543210abcdef/slug-two.html"><z-cover id="5471430" author="Author Two" title="第二本书"><img data-src="https://cdn.example.com/2.jpg"></z-cover></a>
</z-booklist>
<z-booklist id="2690672" href="/booklist/2690672/abc/other-list.html" topic="另一书单" author="someone" authorProfile="/booklists/user/21490583" authorAvatar="" quantity="3" views="8" comments="0" description="desc" color="0"></z-booklist>
</div>
</div>
</body></html>
''';

/// A profile page whose booklists tab carries the paginator, modelled
/// on the live HTML captured 2026-11-21 (issue #11: the tab
/// server-renders at most 10 lists; users with more get
/// `DIV.paginator.paginator_booklists` linking the paginated route).
/// The comments tab's own paginator (`.paginator_comments`) must not
/// be counted — the booklists query is scoped to the booklists tab.
const _profileHtmlPaginated = '''
<html><body>
<div z-tab="comments">
<z-comments total="5"></z-comments>
<div class="paginator paginator_comments">
<a href="/profile/1790607/f094e9/comments?page=2">2</a>
<a href="/profile/1790607/f094e9/comments?page=9">Last</a>
</div>
</div>
<div z-tab="booklists">
<div class="booklists-list">
<z-booklist id="2690671" href="/booklist/2690671/2ac488/math-list.html" topic="数学书单" author="someone" authorProfile="/booklists/user/21490583" authorAvatar="" quantity="15" views="29" comments="0" description="" color="0"></z-booklist>
</div>
<div class="paginator paginator_booklists">
<a href="/profile/1790607/f094e9/booklists?page=1">← Prior</a>
<a href="/profile/1790607/f094e9/booklists?page=2">2</a>
<a href="/profile/1790607/f094e9/booklists?page=3">3</a>
<a href="/profile/1790607/f094e9/booklists?page=10">Next →</a>
<a href="/profile/1790607/f094e9/booklists?page=1">First</a>
<a href="/profile/1790607/f094e9/booklists?page=71">Last</a>
</div>
</div>
</body></html>
''';

/// One paginated document (`/profile/{id}/{hash}/booklists?page=N`,
/// page 2): same full profile shape, next ≤ 10 lists in the tab, its
/// own paginator (live-verified 2026-11-21).
const _profilePage2Html = '''
<html><body>
<div z-tab="booklists">
<div class="booklists-list">
<z-booklist id="2690680" href="/booklist/2690680/abc/page-two-list.html" topic="第二页书单" author="someone" authorProfile="/booklists/user/21490583" authorAvatar="" quantity="7" views="2" comments="0" description="" color="0"></z-booklist>
</div>
<div class="paginator paginator_booklists">
<a href="/profile/1790607/f094e9/booklists?page=1">← Prior</a>
<a href="/profile/1790607/f094e9/booklists?page=3">Next →</a>
<a href="/profile/1790607/f094e9/booklists?page=71">Last</a>
</div>
</div>
</body></html>
''';

void main() {
  group('parseUserProfileBooklists', () {
    test('parses the lists in the booklists tab with preview books', () {
      final lists = parseUserProfileBooklists(
        _profileHtml,
        baseUrl: _baseUrl,
      );
      expect(lists.length, 2);

      final first = lists[0];
      expect(first.id, '2690671');
      expect(first.name, '数学书单');
      // `author` is the display name; the profile path lives in
      // `authorProfile` (an older revision read the path into `author`).
      expect(first.author, 'someone');
      expect(first.authorProfile, '/booklists/user/21490583');
      expect(first.authorAvatar, '');
      expect(first.count, 15);
      expect(first.views, '29');
      expect(first.comments, '0');
      expect(first.color, 0);
      expect(first.isPrivate, isFalse);
      expect(first.isFavorite, isFalse);
      expect(
        first.url,
        '$_baseUrl/booklist/2690671/2ac488/math-list.html',
      );
      expect(
        first.coverUrl,
        'https://cdn.example.com/1.jpg',
      );
      expect(first.previewBooks.length, 2);
      expect(first.previewBooks[0].id, 1045682);
      expect(first.previewBooks[0].title, '第一本书');
      expect(first.previewBooks[0].author, 'Author One');
      expect(first.previewBooks[0].hash, 'abcdef123456');
      expect(
        first.previewBooks[0].cover,
        'https://cdn.example.com/1.jpg',
      );
      expect(first.previewBooks[1].id, 5471430);
      expect(first.previewBooks[1].hash, '9876543210abcdef');

      final second = lists[1];
      expect(second.id, '2690672');
      expect(second.name, '另一书单');
      expect(second.count, 3);
      expect(second.description, 'desc');
      expect(second.previewBooks, isEmpty);
    });

    test('a paginated tab parses its own lists only (paginator ignored)', () {
      final lists = parseUserProfileBooklists(
        _profileHtmlPaginated,
        baseUrl: _baseUrl,
      );
      expect(lists.length, 1);
      expect(lists.single.id, '2690671');
    });

    test('parses the paginated route document (page 2)', () {
      final lists = parseUserProfileBooklists(
        _profilePage2Html,
        baseUrl: _baseUrl,
      );
      expect(lists.length, 1);
      expect(lists.single.id, '2690680');
      expect(lists.single.name, '第二页书单');
    });

    test('an empty booklists tab parses to an empty list', () {
      const html = '''
<html><body>
<div z-tab="comments"><z-comments total="0"></z-comments></div>
<div z-tab="booklists"></div>
</body></html>
''';
      expect(
        parseUserProfileBooklists(html, baseUrl: _baseUrl),
        isEmpty,
      );
    });

    test('a page without the booklists tab parses to an empty list', () {
      const html = '''
<html><body>
<div z-tab="comments"><z-comments total="1"></z-comments></div>
</body></html>
''';
      expect(
        parseUserProfileBooklists(html, baseUrl: _baseUrl),
        isEmpty,
      );
    });
  });

  group('parseUserProfileBooklistsPagesTotal', () {
    test('paginator without one: ≤ 10 lists is one page', () {
      expect(parseUserProfileBooklistsPagesTotal(_profileHtml), 1);
    });

    test('paginator page count is the largest page link, other tabs ignored',
        () {
      // The comments tab carries its own paginator (page=9); the
      // booklists count comes from the booklists tab only — and the
      // "Last" link (page=71) wins over the numbered/Next links.
      expect(parseUserProfileBooklistsPagesTotal(_profileHtmlPaginated), 71);
    });

    test('the paginated route document carries the same total', () {
      expect(parseUserProfileBooklistsPagesTotal(_profilePage2Html), 71);
    });

    test('booklists tab without the paginator element is one page', () {
      const html = '''
<html><body>
<div z-tab="booklists"><div class="booklists-list"></div></div>
</body></html>
''';
      expect(parseUserProfileBooklistsPagesTotal(html), 1);
    });
  });
}
