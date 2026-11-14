import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/services/booklist_html_cache.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('booklist_html_cache');
    Hive.init(tempDir.path);
    await Hive.openBox(BooklistHtmlCache.boxName);
  });

  setUp(() async {
    await Hive.box(BooklistHtmlCache.boxName).clear();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('stores and returns HTML by URL', () {
    BooklistHtmlCache.store(
      'https://example.com/booklists/my',
      '<html>mine</html>',
    );
    expect(
      BooklistHtmlCache.get('https://example.com/booklists/my'),
      '<html>mine</html>',
    );
  });

  test('returns null for unknown URLs', () {
    expect(
      BooklistHtmlCache.get('https://example.com/booklists'),
      isNull,
    );
  });

  test('ignores empty URL and empty HTML', () {
    BooklistHtmlCache.store('', '<html/>');
    BooklistHtmlCache.store('https://example.com/x', '');
    expect(BooklistHtmlCache.get(''), isNull);
    expect(BooklistHtmlCache.get('https://example.com/x'), isNull);
  });

  test('a newer store overwrites an older one', () {
    const url = 'https://example.com/booklists/my';
    BooklistHtmlCache.store(url, '<html>old</html>');
    BooklistHtmlCache.store(url, '<html>new</html>');
    expect(BooklistHtmlCache.get(url), '<html>new</html>');
  });

  test('entries older than the TTL read as absent', () {
    final box = Hive.box(BooklistHtmlCache.boxName);
    final staleAt = DateTime.now()
        .subtract(BooklistHtmlCache.ttl + const Duration(seconds: 1))
        .millisecondsSinceEpoch;
    box.put('https://example.com/old', {
      'at': staleAt,
      'html': '<html>old</html>',
    });
    expect(BooklistHtmlCache.get('https://example.com/old'), isNull);
  });

  test('corrupt entries read as absent', () {
    final box = Hive.box(BooklistHtmlCache.boxName);
    box.put('https://example.com/broken', {'nope': true});
    box.put('https://example.com/broken-at', {
      'at': 'not-a-number',
      'html': '<html/>',
    });
    expect(BooklistHtmlCache.get('https://example.com/broken'), isNull);
    expect(
      BooklistHtmlCache.get('https://example.com/broken-at'),
      isNull,
    );
  });

  test('evicts the oldest entries past the cap', () {
    final box = Hive.box(BooklistHtmlCache.boxName);
    // Hand-built entries with increasing timestamps: the first one
    // is the oldest and must go when one more store pushes the box
    // past the cap. (Hand-built timestamps are long past the TTL,
    // so presence is checked on the box itself, not through get.)
    for (var i = 0; i < BooklistHtmlCache.maxEntries; i++) {
      box.put('https://example.com/$i', {
        'at': 1000 + i,
        'html': '<html>$i</html>',
      });
    }
    BooklistHtmlCache.store(
      'https://example.com/new',
      '<html>new</html>',
    );
    expect(box.length, BooklistHtmlCache.maxEntries);
    expect(box.containsKey('https://example.com/0'), isFalse);
    expect(box.containsKey('https://example.com/1'), isTrue);
    expect(
      BooklistHtmlCache.get('https://example.com/new'),
      '<html>new</html>',
    );
  });

  test('clear empties the cache', () async {
    BooklistHtmlCache.store(
      'https://example.com/booklists/my',
      '<html>mine</html>',
    );
    await BooklistHtmlCache.clear();
    expect(
      BooklistHtmlCache.get('https://example.com/booklists/my'),
      isNull,
    );
  });

  test('isPrivateUrl partitions only account-scoped pages', () {
    expect(
      BooklistHtmlCache.isPrivateUrl('https://example.com/booklists/my'),
      isTrue,
    );
    expect(
      BooklistHtmlCache.isPrivateUrl(
        'https://example.com/booklists/my?searchQuery=x&page=1',
      ),
      isTrue,
    );
    expect(
      BooklistHtmlCache.isPrivateUrl(
        'https://example.com/booklist/4088695/62a0c2/001.html',
      ),
      isTrue,
    );
    expect(
      BooklistHtmlCache.isPrivateUrl('https://example.com/booklists'),
      isFalse,
    );
    expect(
      BooklistHtmlCache.isPrivateUrl(
        'https://example.com/profile/22418238/d2e9c8',
      ),
      isFalse,
    );
    expect(BooklistHtmlCache.isPrivateUrl('not a url'), isFalse);
  });

  test('account partitions isolate the same URL', () {
    const url = 'https://example.com/booklists/my';
    BooklistHtmlCache.store(url, '<html>mine-A</html>', accountId: '111');
    BooklistHtmlCache.store(url, '<html>mine-B</html>', accountId: '222');
    expect(
      BooklistHtmlCache.get(url, accountId: '111'),
      '<html>mine-A</html>',
    );
    expect(
      BooklistHtmlCache.get(url, accountId: '222'),
      '<html>mine-B</html>',
    );
    // The public (unpartitioned) key never sees either account's page.
    expect(BooklistHtmlCache.get(url), isNull);
  });

  test('stores and returns a JSON books page', () {
    const url = 'https://example.com/booklist/1/hash/slug.html';
    const books = [
      Book(id: 1, title: 'First', author: 'A', hash: 'aaa'),
      Book(id: 2, title: 'Second', author: 'B', hash: 'bbb'),
    ];
    BooklistHtmlCache.storeBooksPage(url, 2, books, accountId: '111');
    final read = BooklistHtmlCache.getBooksPage(url, 2, accountId: '111');
    expect(read, isNotNull);
    expect(read!.length, 2);
    expect(read[0].id, 1);
    expect(read[0].title, 'First');
    expect(read[0].author, 'A');
    expect(read[0].hash, 'aaa');
    expect(read[1].id, 2);
    // A different page, a different account, and the public key
    // all miss.
    expect(BooklistHtmlCache.getBooksPage(url, 3, accountId: '111'), isNull);
    expect(BooklistHtmlCache.getBooksPage(url, 2, accountId: '222'), isNull);
    expect(BooklistHtmlCache.getBooksPage(url, 2), isNull);
  });

  test('stale and corrupt JSON pages read as absent', () {
    final box = Hive.box(BooklistHtmlCache.boxName);
    final staleAt = DateTime.now()
        .subtract(BooklistHtmlCache.ttl + const Duration(seconds: 1))
        .millisecondsSinceEpoch;
    const url = 'https://example.com/booklist/1/h/s.html';
    box.put('$url#json-page=2#account=111', {
      'at': staleAt,
      'books': [
        {'id': 1, 'title': 'Old'},
      ],
    });
    box.put('$url#json-page=3#account=111', {
      'at': DateTime.now().millisecondsSinceEpoch,
      'books': 'not-a-list',
    });
    expect(
      BooklistHtmlCache.getBooksPage(url, 2, accountId: '111'),
      isNull,
    );
    expect(
      BooklistHtmlCache.getBooksPage(url, 3, accountId: '111'),
      isNull,
    );
  });

  test('JSON pages share the entry cap', () {
    final box = Hive.box(BooklistHtmlCache.boxName);
    for (var i = 0; i < BooklistHtmlCache.maxEntries; i++) {
      box.put('https://example.com/$i', {
        'at': 1000 + i,
        'html': '<html>$i</html>',
      });
    }
    BooklistHtmlCache.storeBooksPage(
      'https://example.com/booklist/1/h/s.html',
      2,
      const [Book(id: 1, title: 'New')],
      accountId: '111',
    );
    expect(box.length, BooklistHtmlCache.maxEntries);
    expect(box.containsKey('https://example.com/0'), isFalse);
    expect(
      BooklistHtmlCache.getBooksPage(
        'https://example.com/booklist/1/h/s.html',
        2,
        accountId: '111',
      )!.length,
      1,
    );
  });

  // Item 4 (cache consistency): a fetch that started before an
  // invalidation must not re-store its stale page afterwards.
  test('store drops a write whose fetch started before an invalidation', () {
    const url = 'https://example.com/booklist/stale-write/h/s.html';
    final fetchedAt = DateTime.now().subtract(const Duration(seconds: 1));
    BooklistHtmlCache.invalidateBooklist(url);
    BooklistHtmlCache.store(url, '<html>stale</html>', fetchedAt: fetchedAt);
    expect(BooklistHtmlCache.get(url), isNull);
    // A fetch that started after the invalidation lands normally.
    BooklistHtmlCache.store(
      url,
      '<html>fresh</html>',
      fetchedAt: DateTime.now().add(const Duration(seconds: 1)),
    );
    expect(BooklistHtmlCache.get(url), '<html>fresh</html>');
  });

  test('storeBooksPage drops a stale write after an invalidation', () {
    const url = 'https://example.com/booklist/stale-page/h/s.html';
    final fetchedAt = DateTime.now().subtract(const Duration(seconds: 1));
    BooklistHtmlCache.invalidateBooklist(url, accountId: '111');
    BooklistHtmlCache.storeBooksPage(
      url,
      2,
      const [Book(id: 9, title: 'Stale')],
      accountId: '111',
      fetchedAt: fetchedAt,
    );
    expect(
      BooklistHtmlCache.getBooksPage(url, 2, accountId: '111'),
      isNull,
    );
    // A fetch that started after the invalidation lands normally.
    BooklistHtmlCache.storeBooksPage(
      url,
      2,
      const [Book(id: 9, title: 'Fresh')],
      accountId: '111',
      fetchedAt: DateTime.now().add(const Duration(seconds: 1)),
    );
    expect(
      BooklistHtmlCache.getBooksPage(url, 2, accountId: '111')!.length,
      1,
    );
  });

  test('store without fetchedAt still writes', () {
    const url = 'https://example.com/booklist/no-fetch-time/h/s.html';
    BooklistHtmlCache.invalidateBooklist(url);
    BooklistHtmlCache.store(url, '<html>legacy</html>');
    expect(BooklistHtmlCache.get(url), '<html>legacy</html>');
  });

  test('wasInvalidatedAfter reports an invalidation after a fetch', () {
    const url = 'https://example.com/booklist/tombstone/h/s.html';
    final before = DateTime.now().subtract(const Duration(seconds: 1));
    expect(
      BooklistHtmlCache.wasInvalidatedAfter(url, before),
      isFalse,
    );
    BooklistHtmlCache.invalidateBooklist(url);
    expect(
      BooklistHtmlCache.wasInvalidatedAfter(url, before),
      isTrue,
    );
    expect(
      BooklistHtmlCache.wasInvalidatedAfter(
        url,
        DateTime.now().add(const Duration(seconds: 1)),
      ),
      isFalse,
    );
  });

  // The two tests below pin the ordering itself, not a wall-clock gap.
  // On Windows the VM's DateTime.now advances roughly every 2 ms
  // (measured: back-to-back calls returned the identical stamp
  // 1000/1000), so "invalidate, then start a load" can produce two equal
  // stamps — and wasInvalidatedAfter must read "not strictly later" as
  // stale. That dropped a perfectly fresh page and made
  // test/providers/booklist_detail_state_test.dart flip between runs on
  // this machine. stamp() is monotonic, so the ordering no longer depends
  // on how coarse the platform clock happens to be; on Linux both the old
  // and the new code pass, which is exactly why the property needs its own
  // test instead of relying on the suite going green.
  test('stamp hands out a strictly increasing sequence back to back', () {
    DateTime? previous;
    for (var i = 0; i < 500; i++) {
      final current = BooklistHtmlCache.stamp();
      if (previous != null) {
        expect(
          current.isAfter(previous),
          isTrue,
          reason: 'stamp #${i + 1} did not beat the previous one — the '
              'generator is reading the raw wall clock again',
        );
      }
      previous = current;
    }
  });

  test('a load stamped after an invalidation is not treated as stale', () {
    const url = 'https://example.com/booklist/monotonic/h/s.html';
    // Delete completes, THEN the next page load starts: the load must win,
    // even when nothing but a microsecond of work separates the two.
    BooklistHtmlCache.invalidateBooklist(url);
    final startedAfter = BooklistHtmlCache.stamp();
    expect(
      BooklistHtmlCache.wasInvalidatedAfter(url, startedAfter),
      isFalse,
      reason: 'a fetch that started after the write was classified stale',
    );
    // And the guard still guards: a fetch that predates the write loses.
    final startedBefore = BooklistHtmlCache.stamp();
    BooklistHtmlCache.invalidateBooklist(url);
    expect(
      BooklistHtmlCache.wasInvalidatedAfter(url, startedBefore),
      isTrue,
      reason: 'a stale fetch would have resurrected the removed book',
    );
  });
}
