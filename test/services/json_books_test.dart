import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

/// Differential test for the eapi book-list JSON sink.
///
/// `ZLibraryApiBase.fallbackBooksOf` decodes raw JSON text through the
/// Dart `_booksOf` + `Book.fromJson` pipeline — the exact contract the
/// Rust `parse_books_json` must match (rust/zlibx_parsers/src/json_books.rs).
/// When the host app injects `booksParseOverride`, the same inputs are
/// parsed in Rust; both paths must produce byte-identical Book fields.
/// CI has no Rust toolchain, so this file pins the Dart baseline that the
/// Rust port is diffed against (CLAUDE.md: "port a parser only alongside
/// its twin test").
void main() {
  List<Book> parse(String json) => ZLibraryApiBase.fallbackBooksOf(json);

  group('array key selection', () {
    test('reads books / data / results', () {
      expect(parse('{"books":[{"id":1,"title":"a"}]}').length, 1);
      expect(parse('{"data":[{"id":2,"title":"b"}]}').length, 1);
      expect(parse('{"results":[{"id":3,"title":"c"}]}').length, 1);
    });

    test('no recognized array yields empty', () {
      expect(parse('{"pagination":{"total":0}}'), isEmpty);
    });

    test('invalid JSON yields empty (never throws)', () {
      expect(parse('not json at all'), isEmpty);
    });

    test('non-object elements are skipped', () {
      final books = parse('{"books":[{"id":1},42,"str",null,{"id":2}]}');
      expect(books.map((b) => b.id), [1, 2]);
    });
  });

  group('core field mapping', () {
    test('id defaults to 0 when absent or unparsable', () {
      expect(parse('{"books":[{"title":"t"}]}')[0].id, 0);
      expect(parse('{"books":[{"id":"abc","title":"t"}]}')[0].id, 0);
    });

    test('title defaults to empty string', () {
      expect(parse('{"books":[{"id":1}]}')[0].title, '');
    });

    test('double id truncates toward zero like Dart toInt()', () {
      expect(parse('{"books":[{"id":7.9,"title":"t"}]}')[0].id, 7);
    });

    test('string id is parsed', () {
      expect(parse('{"books":[{"id":"88","title":"t"}]}')[0].id, 88);
    });
  });

  group('hash derivation', () {
    test('prefers explicit hash over href', () {
      final b = parse(
        '{"books":[{"id":1,"hash":"EXPLICIT","href":"/book/fromHref/x.html"}]}',
      )[0];
      expect(b.hash, 'EXPLICIT');
    });

    test('falls back to href-derived hash when hash absent', () {
      final b = parse(
        '{"books":[{"id":1,"href":"/book/eOWaxzXxjb/title.html"}]}',
      )[0];
      expect(b.hash, 'eOWaxzXxjb');
    });

    test('empty hash string does not shadow the href fallback', () {
      final b = parse(
        '{"books":[{"id":1,"hash":"","href":"/book/fromHref/x.html"}]}',
      )[0];
      expect(b.hash, 'fromHref');
    });

    test('hashId alias is honored', () {
      final b = parse('{"books":[{"id":1,"hashId":"ALIAS"}]}')[0];
      expect(b.hash, 'ALIAS');
    });

    test('href without book shape leaves hash null', () {
      final b = parse('{"books":[{"id":1,"href":"/other/path"}]}')[0];
      expect(b.hash, isNull);
    });
  });

  group('author / categories joining', () {
    test('author list joins with comma-space', () {
      final b = parse(
        '{"books":[{"id":1,"author":["张三","李四"]}]}',
      )[0];
      expect(b.author, '张三, 李四');
    });

    test('author scalar passes through', () {
      final b = parse('{"books":[{"id":1,"author":"Single"}]}')[0];
      expect(b.author, 'Single');
    });

    test('categories list joins; empty list normalizes to null', () {
      expect(
        parse('{"books":[{"id":1,"categories":["Fiction","Horror"]}]}')[0]
            .categories,
        'Fiction, Horror',
      );
      expect(
        parse('{"books":[{"id":1,"categories":[]}]}')[0].categories,
        isNull,
      );
    });

    test('categories single string kept', () {
      expect(
        parse('{"books":[{"id":1,"categories":"Fiction - Horror"}]}')[0]
            .categories,
        'Fiction - Horror',
      );
    });
  });

  group('filesize formatting', () {
    test('explicit filesizeString wins', () {
      final b = parse(
        '{"books":[{"id":1,"filesize":999,"filesizeString":"custom"}]}',
      )[0];
      expect(b.filesizeString, 'custom');
    });

    test('bytes format by binary unit', () {
      String fs(int bytes) =>
          parse('{"books":[{"id":1,"filesize":$bytes}]}')[0].filesizeString!;
      expect(fs(512), '512 B');
      expect(fs(1024), '1.0 KB');
      expect(fs(1536), '1.5 KB');
      expect(fs(1024 * 1024), '1.00 MB');
      expect(fs(1024 * 1024 * 1024), '1.00 GB');
    });

    test('absent filesize leaves string null', () {
      expect(parse('{"books":[{"id":1}]}')[0].filesizeString, isNull);
    });
  });

  group('optional non-empty normalization', () {
    test('empty optional strings become null', () {
      final b = parse(
        '{"books":[{"id":1,"volume":"","isbn10":"","note":""}]}',
      )[0];
      expect(b.volume, isNull);
      expect(b.isbn10, isNull);
      expect(b.note, isNull);
    });

    test('snake_case aliases map too', () {
      final b = parse(
        '{"books":[{"id":1,"isbn_13":"978","read_online_url":"u",'
        '"interest_score":"3.0","ipfs_cid":"cid"}]}',
      )[0];
      expect(b.isbn13, '978');
      expect(b.readOnlineUrl, 'u');
      expect(b.interestScore, '3.0');
      expect(b.ipfsCid, 'cid');
    });

    test('remaining snake_case aliases: isbn_10, filesize_string, readlist_book_id, ipfs_cid_blake2b', () {
      final b = parse(
        '{"books":[{"id":1,"isbn_10":"123","filesize_string":"2 MB",'
        '"readlist_book_id":42,"ipfs_cid_blake2b":"blake"}]}',
      )[0];
      expect(b.isbn10, '123');
      expect(b.filesizeString, '2 MB');
      expect(b.readlistBookId, 42);
      expect(b.ipfsCidBlake2b, 'blake');
    });

    test('qualityScore alias maps to interestScore', () {
      final b = parse(
        '{"books":[{"id":1,"qualityScore":"4.5"}]}',
      )[0];
      expect(b.interestScore, '4.5');
    });

    test('cover, description, series fields map correctly', () {
      final b = parse(
        '{"books":[{"id":1,"cover":"https://img/c.jpg",'
        '"description":"A book desc","series":"Series Name"}]}',
      )[0];
      expect(b.cover, 'https://img/c.jpg');
      expect(b.description, 'A book desc');
      expect(b.series, 'Series Name');
    });
  });

  group('downloadedAt round-trip', () {
    test('ISO string parses to DateTime', () {
      final b = parse(
        '{"books":[{"id":1,"downloadedAt":"2026-11-11T21:02:00"}]}',
      )[0];
      expect(b.downloadedAt, DateTime(2026, 11, 11, 21, 2));
    });

    test('epoch seconds convert', () {
      // Derive the epoch from the target instant so the test is TZ-safe:
      // Dart's DateTime.utc(...).millisecondsSinceEpoch is the ground truth.
      final epochMs = DateTime.utc(2026, 11, 11, 21, 2).millisecondsSinceEpoch;
      final b = parse('{"books":[{"id":1,"downloaded_at":${epochMs ~/ 1000}}]}')[0];
      expect(b.downloadedAt!.toUtc(), DateTime.utc(2026, 11, 11, 21, 2));
    });

    test('zero / absurd epoch stays null', () {
      expect(parse('{"books":[{"id":1,"downloadedAt":0}]}')[0].downloadedAt,
          isNull);
      expect(
        parse('{"books":[{"id":1,"downloadedAt":999999999999999}]}')[0]
            .downloadedAt,
        isNull,
      );
    });
  });

  test('full realistic payload maps every populated field', () {
    const payload = '''
    {"success":1,"books":[
      {"id":23787383,"title":"男人就愛吃這套",
       "href":"https://z-lib.sk/book/eOWaxzXxjb/%E7%94%B7%E4%BA%BA.html",
       "author":["Anonymous"],"publisher":"PUB","year":2019,
       "language":"zh","pages":300,"extension":"epub",
       "filesize":1048576,"categories":["Self-Help"],
       "interestScore":"3.0"}
    ]}''';
    final b = parse(payload)[0];
    expect(b.id, 23787383);
    expect(b.title, '男人就愛吃這套');
    expect(b.hash, 'eOWaxzXxjb');
    expect(b.author, 'Anonymous');
    expect(b.publisher, 'PUB');
    expect(b.year, 2019);
    expect(b.language, 'zh');
    expect(b.pages, 300);
    expect(b.extension, 'epub');
    expect(b.filesize, 1048576);
    expect(b.filesizeString, '1.00 MB');
    expect(b.categories, 'Self-Help');
    expect(b.interestScore, '3.0');
  });

  test('the decoded-map path matches the raw-text fallback', () {
    // Book.fromJson (map) and fallbackBooksOf (raw text) must agree — one
    // is the primary Dart entry, the other what the Rust hook falls back to.
    const payload =
        '{"books":[{"id":5,"title":"x","author":["A","B"],"filesize":2048}]}';
    final viaMap = Book.fromJson(
      (jsonDecode(payload)['books'] as List).first as Map<String, dynamic>,
    );
    final viaText = parse(payload).single;
    expect(viaText.id, viaMap.id);
    expect(viaText.title, viaMap.title);
    expect(viaText.author, viaMap.author);
    expect(viaText.filesizeString, viaMap.filesizeString);
  });
}
