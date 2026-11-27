// TXT → EPUB: heading regex, 200 KB cap, encodings, cache.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/txt_to_epub.dart';

int bytesOf(TxtChapter c) =>
    c.paragraphs.fold<int>(0, (n, p) => n + utf8.encode(p).length);

void main() {
  group('chapter headings', () {
    test('recognises common heading shapes', () {
      for (final line in [
        '第一章 开端',
        '第12章',
        '第 三 节 风起',
        '第一百二十回 尾声',
        'Chapter 7',
        'CHAPTER IV The Storm',
        '序章',
        '楔子',
      ]) {
        expect(isChapterHeading(line), isTrue, reason: line);
      }
    });

    test('rejects ordinary lines', () {
      expect(isChapterHeading('他说第一章已经写完了，然后离开了房间，再也没有回来过。'), isFalse);
      expect(isChapterHeading(''), isFalse);
      expect(isChapterHeading('Chapters are fun'), isFalse);
    });
  });

  group('splitChapters', () {
    test('splits on headings and keeps titles', () {
      const text = '第一章 开始\n这是第一段。\n\n这是第二段。\n\n第二章 继续\n另一章的内容。\n';
      final chapters = splitChapters(text, fallbackTitle: 'Book');
      expect(chapters.map((c) => c.title), ['第一章 开始', '第二章 继续']);
      expect(chapters[0].paragraphs, ['这是第一段。', '这是第二段。']);
      expect(chapters[1].paragraphs, ['另一章的内容。']);
    });

    test('text before the first heading becomes its own chapter', () {
      const text = '前面的话\n\n第一章 正文\n内容\n';
      final chapters = splitChapters(text, fallbackTitle: 'Book');
      expect(chapters.first.title, 'Book');
      expect(chapters.length, 2);
    });

    test('no headings → one chapter titled after the book', () {
      final chapters = splitChapters('一\n二\n三\n', fallbackTitle: 'Book');
      expect(chapters.length, 1);
      expect(chapters.single.title, 'Book');
      // No blank lines at all: one paragraph per line.
      expect(chapters.single.paragraphs, ['一', '二', '三']);
    });

    test('a long chapter is cut at the 200 KB cap', () {
      final para = 'a' * 1000;
      final body = List.filled(300, para).join('\n\n'); // ~300 KB
      final chapters = splitChapters('第一章 长\n$body\n', fallbackTitle: 'Book');
      expect(chapters.length, greaterThanOrEqualTo(2));
      for (final c in chapters) {
        expect(bytesOf(c), lessThanOrEqualTo(kTxtChapterByteLimit));
      }
      final total = chapters.fold<int>(0, (n, c) => n + bytesOf(c));
      expect(total, 300 * 1000);
    });

    test('one oversized paragraph is cut too', () {
      final chapters = splitChapters(
        '第一章 长\n${'字' * 120000}\n',
        fallbackTitle: 'Book',
      );
      expect(chapters.length, greaterThanOrEqualTo(2));
      for (final c in chapters) {
        expect(bytesOf(c), lessThanOrEqualTo(kTxtChapterByteLimit));
      }
    });
  });

  group('decodeTxtBytes', () {
    test('UTF-8', () {
      expect(
        decodeTxtBytes(Uint8List.fromList(utf8.encode('第一章\n你好世界\n'))),
        '第一章\n你好世界\n',
      );
    });

    test('UTF-8 with BOM', () {
      final bytes = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('你好'),
      ]);
      expect(decodeTxtBytes(bytes), '你好');
    });

    test('UTF-16 LE with BOM', () {
      final bytes = Uint8List.fromList([0xFF, 0xFE, 0x60, 0x4F, 0x7D, 0x59]);
      expect(decodeTxtBytes(bytes), '你好');
    });

    test('GBK sample decodes correctly (not mojibake)', () {
      // "第一章\n你好世界\n" in GBK.
      final bytes = Uint8List.fromList([
        0xB5, 0xDA, 0xD2, 0xBB, 0xD5, 0xC2, 0x0A, //
        0xC4, 0xE3, 0xBA, 0xC3, 0xCA, 0xC0, 0xBD, 0xE7, 0x0A,
      ]);
      expect(decodeTxtBytes(bytes), '第一章\n你好世界\n');
    });
  });

  test('FNV-1a known vectors and key sensitivity', () {
    expect(fnv1a64Hex(''), 'cbf29ce484222325');
    expect(fnv1a64Hex('a'), 'af63dc4c8601ec8c');

    final t = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final k = txtCacheKey('/a/b.txt', 10, t);
    expect(k, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(txtCacheKey('/a/b.txt', 10, t), k);
    expect(txtCacheKey('/a/c.txt', 10, t), isNot(k));
    expect(txtCacheKey('/a/b.txt', 11, t), isNot(k));
    expect(
      txtCacheKey('/a/b.txt', 10, t.add(const Duration(seconds: 1))),
      isNot(k),
    );
  });

  group('buildEpub / TxtToEpub', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('txt_epub_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('mimetype first and stored; spine matches chapters', () {
      final bytes = buildEpub(
        title: 'T',
        chapters: const [
          TxtChapter('一', ['p1']),
          TxtChapter('二 <&>', ['p2']),
        ],
        identifier: 'urn:test',
      );
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.files.first.name, 'mimetype');
      final names = archive.files.map((f) => f.name).toSet();
      expect(
        names,
        containsAll(<String>[
          'META-INF/container.xml',
          'OEBPS/content.opf',
          'OEBPS/toc.ncx',
          'OEBPS/ch0001.xhtml',
          'OEBPS/ch0002.xhtml',
        ]),
      );
      final ch2 = utf8.decode(
        archive.files.firstWhere((f) => f.name == 'OEBPS/ch0002.xhtml').content
            as List<int>,
      );
      expect(ch2, contains('二 &lt;&amp;&gt;'));
    });

    test('second open of the same file is served from the cache', () async {
      final cache = Directory('${tmp.path}/cache');
      final converter = TxtToEpub(cacheDir: () async => cache);
      final file = File('${tmp.path}/book.txt')
        ..writeAsStringSync('第一章 开始\n内容\n\n第二章 继续\n更多\n');

      final first = await converter.epubFor(file.path);
      final second = await converter.epubFor(file.path);
      expect(converter.conversions, 1);
      expect(second, first);

      // A changed file (new size) is converted again.
      file.writeAsStringSync('第一章 开始\n内容变长了很多很多\n');
      await converter.epubFor(file.path);
      expect(converter.conversions, 2);
    });

    test('concurrent opens share one conversion', () async {
      final cache = Directory('${tmp.path}/cache');
      final converter = TxtToEpub(cacheDir: () async => cache);
      final file = File('${tmp.path}/book.txt')
        ..writeAsStringSync('第一章 开始\n内容\n');

      final files = await Future.wait([
        converter.epubFileFor(file.path),
        converter.epubFileFor(file.path),
        converter.epubFileFor(file.path),
      ]);
      expect(converter.conversions, 1);
      expect(files.map((file) => file.path).toSet(), hasLength(1));
    });

    test('an invalid cache entry is rebuilt', () async {
      final cache = Directory('${tmp.path}/cache');
      final converter = TxtToEpub(cacheDir: () async => cache);
      final file = File('${tmp.path}/book.txt')
        ..writeAsStringSync('第一章 开始\n内容\n');

      final first = await converter.epubFileFor(file.path);
      first.writeAsStringSync('broken cache entry');
      final second = await converter.epubFileFor(file.path);
      expect(converter.conversions, 2);
      expect(second.path, first.path);
      expect(second.readAsBytesSync().take(2), [0x50, 0x4b]);
    });

    test(
      'cache pruning keeps the newest file and at most 128 entries',
      () async {
        final cache = Directory('${tmp.path}/cache');
        cache.createSync();
        final staging = File('${cache.path}/0123456789abcdef.epub.part')
          ..writeAsStringSync('still being written');
        final converter = TxtToEpub(cacheDir: () async => cache);
        late File newest;
        for (var i = 0; i < 130; i++) {
          final file = File('${tmp.path}/book$i.txt')
            ..writeAsStringSync('第$i章 内容\n');
          newest = await converter.epubFileFor(file.path);
        }

        final entries = cache.listSync().whereType<File>().where(
          (file) => file.path.endsWith('.epub'),
        );
        expect(entries, hasLength(128));
        expect(staging.existsSync(), isFalse);
        expect(newest.existsSync(), isTrue);
        expect(converter.conversions, 130);
      },
    );

    test(
      'a cache write failure falls back to a readable temporary EPUB',
      () async {
        File(
          '${tmp.path}/not-a-directory',
        ).writeAsStringSync('not a directory');
        final converter = TxtToEpub(
          cacheDir: () async => Directory('${tmp.path}/not-a-directory'),
        );
        final file = File('${tmp.path}/book.txt')
          ..writeAsStringSync('第一章 开始\n内容\n');

        final fallback = await converter.epubFileFor(file.path);
        addTearDown(() async {
          if (await fallback.exists()) await fallback.delete();
        });
        expect(fallback.parent.path, Directory.systemTemp.path);
        expect(fallback.path, contains('zlibx-txt-'));
        expect(fallback.readAsBytesSync().take(2), [0x50, 0x4b]);
      },
    );

    test('GBK file converts end to end', () async {
      final converter = TxtToEpub(
        cacheDir: () async => Directory('${tmp.path}/c'),
      );
      final file = File('${tmp.path}/gbk.txt')
        ..writeAsBytesSync([
          0xB5,
          0xDA,
          0xD2,
          0xBB,
          0xD5,
          0xC2,
          0x0A,
          0xC4,
          0xE3,
          0xBA,
          0xC3,
          0xCA,
          0xC0,
          0xBD,
          0xE7,
          0x0A,
        ]);
      final epub = await converter.epubFor(file.path);
      final archive = ZipDecoder().decodeBytes(epub);
      final ch = utf8.decode(
        archive.files.firstWhere((f) => f.name == 'OEBPS/ch0001.xhtml').content
            as List<int>,
      );
      expect(ch, contains('你好世界'));
    });

    test('empty or missing files fail with a readable exception', () async {
      final converter = TxtToEpub(
        cacheDir: () async => Directory('${tmp.path}/c'),
      );
      final empty = File('${tmp.path}/empty.txt')..writeAsStringSync('  \n ');
      await expectLater(
        converter.epubFor(empty.path),
        throwsA(isA<TxtConvertException>()),
      );
      await expectLater(
        converter.epubFor('${tmp.path}/nope.txt'),
        throwsA(isA<TxtConvertException>()),
      );
    });
  });
}
