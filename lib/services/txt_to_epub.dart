// TXT → minimal EPUB 2, done on the fly for the web reader.
//
// foliate-js cannot open plain text, so when the user taps "read" on a
// TXT book the web service converts it to an EPUB first and hands that
// to the reader; from then on the book behaves exactly like an EPUB
// (table of contents, saved position, ...).
//
// Pipeline: decode (encoding probe) → split into chapters (heading
// regex, 200 KB cap per part) → pack a minimal EPUB 2 → cache the
// result keyed by FNV-1a(path + size + mtime).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chinese_codec/chinese_codec.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Upper bound for one chapter part (UTF-8 bytes of the source text).
/// Longer chapters are cut so no single page in the reader is huge.
const int kTxtChapterByteLimit = 200 * 1024;

/// Thrown when a TXT cannot be converted (all encodings failed, empty
/// file, ...). The web service turns it into a readable error page;
/// the book's download link is unaffected.
class TxtConvertException implements Exception {
  final String message;
  const TxtConvertException(this.message);

  @override
  String toString() => 'TxtConvertException: $message';
}

/// One chapter (or one ≤200 KB part of a long chapter).
class TxtChapter {
  final String title;

  /// Paragraphs, already split (blank-line separated blocks).
  final List<String> paragraphs;

  const TxtChapter(this.title, this.paragraphs);
}

// ───────────────────────── Encoding detection ─────────────────────────
//
// Order is a hard requirement — a GBK book decoded as UTF-8 first
// "succeeds" with mojibake if the strictness is wrong:
//   BOM → strict UTF-8 → strict GBK → strict GB18030 → lenient GBK.

/// Decode [bytes] to text, or null when nothing works.
String? decodeTxtBytes(Uint8List bytes) {
  if (bytes.isEmpty) return '';

  // 1. BOM.
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: false);
  }

  // 2. Strict UTF-8.
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // fall through
  }

  // 3. Strict GBK, 4. strict GB18030, 5. lenient GBK.
  return _gbkStrict(bytes) ?? _gb18030Strict(bytes) ?? _gbkLenient(bytes);
}

String _decodeUtf16(Uint8List body, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < body.length; i += 2) {
    units.add(
      littleEndian ? body[i] | (body[i + 1] << 8) : (body[i] << 8) | body[i + 1],
    );
  }
  return String.fromCharCodes(units);
}

// ── chinese_codec adapter ───────────────────────────────────────────
// The ONLY place that touches the chinese_codec API. It is written from
// the package's documented `gbk` / `gb18030` codec objects and has NOT
// been compiled in the authoring environment (no Dart toolchain, no
// pub access): if CI complains here, fix just these three functions.

String? _gbkStrict(Uint8List bytes) {
  try {
    return gbk.decode(bytes);
  } catch (_) {
    return null;
  }
}

String? _gb18030Strict(Uint8List bytes) {
  try {
    return gb18030.decode(bytes);
  } catch (_) {
    return null;
  }
}

/// Lenient GBK: decode line by line so one corrupt line cannot sink the
/// whole book; a line that still fails is kept as lossy UTF-8.
String _gbkLenient(Uint8List bytes) {
  final out = StringBuffer();
  var start = 0;
  for (var i = 0; i <= bytes.length; i++) {
    if (i == bytes.length || bytes[i] == 0x0A) {
      final end = i < bytes.length ? i + 1 : i;
      if (end > start) {
        final line = Uint8List.sublistView(bytes, start, end);
        out.write(_gbkStrict(line) ?? utf8.decode(line, allowMalformed: true));
      }
      start = end;
    }
  }
  return out.toString();
}

// ───────────────────────── Chapter splitting ─────────────────────────

/// Heading lines: 第X章/节/回/卷/集/部/篇…, Chapter N, 序章/楔子/后记/尾声/番外.
final RegExp _headingPattern = RegExp(
  r'^\s*('
  r'第\s*[0-9零〇一二三四五六七八九十百千万两]+\s*[章节回卷集部篇].{0,40}'
  r'|(?:Chapter|CHAPTER)\s+(?:\d+|[IVXLCivxlc]+).{0,40}'
  r'|序章|楔子|引子|前言|后记|尾声|终章|番外.{0,20}'
  r')\s*$',
);

/// Whether a single line looks like a chapter heading.
bool isChapterHeading(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty || trimmed.length > 60) return false;
  return _headingPattern.hasMatch(trimmed);
}

int _utf8Len(String s) => utf8.encode(s).length;

/// Split [text] into chapters by heading lines, then cut any chapter
/// whose body exceeds [maxBytes] into numbered parts.
///
/// Paragraphs are the blank-line separated blocks. A text with no blank
/// lines at all (one line per paragraph is common in Chinese TXT) gets
/// one paragraph per line instead of one giant block.
List<TxtChapter> splitChapters(
  String text, {
  required String fallbackTitle,
  int maxBytes = kTxtChapterByteLimit,
}) {
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

  final rawChapters = <_RawChapter>[];
  var current = _RawChapter(fallbackTitle);
  for (final line in lines) {
    if (isChapterHeading(line)) {
      if (current.hasBody || rawChapters.isNotEmpty) {
        if (current.hasBody) rawChapters.add(current);
      }
      current = _RawChapter(line.trim());
    } else {
      current.lines.add(line);
    }
  }
  if (current.hasBody || rawChapters.isEmpty) rawChapters.add(current);

  final result = <TxtChapter>[];
  for (final raw in rawChapters) {
    final paragraphs = _toParagraphs(raw.lines);
    result.addAll(_capChapter(raw.title, paragraphs, maxBytes));
  }
  return result;
}

class _RawChapter {
  final String title;
  final List<String> lines = <String>[];
  _RawChapter(this.title);
  bool get hasBody => lines.any((l) => l.trim().isNotEmpty);
}

List<String> _toParagraphs(List<String> lines) {
  // A trailing newline leaves a trailing empty line after split('\n');
  // it is not a blank-line separator, so drop trailing blank lines
  // before deciding whether the text has any.
  var end = lines.length;
  while (end > 0 && lines[end - 1].trim().isEmpty) {
    end--;
  }
  final effective = lines.sublist(0, end);

  final blocks = <String>[];
  final buffer = <String>[];
  var sawBlank = false;
  void flush() {
    if (buffer.isNotEmpty) {
      blocks.add(buffer.join('\n'));
      buffer.clear();
    }
  }

  for (final line in effective) {
    if (line.trim().isEmpty) {
      sawBlank = true;
      flush();
    } else {
      buffer.add(line.trim());
    }
  }
  flush();
  if (!sawBlank) {
    // No blank lines anywhere: every line is its own paragraph.
    return [for (final b in blocks) ...b.split('\n')];
  }
  return blocks;
}

List<TxtChapter> _capChapter(
  String title,
  List<String> paragraphs,
  int maxBytes,
) {
  // Break any single paragraph that alone exceeds the cap.
  final pieces = <String>[];
  for (final para in paragraphs) {
    if (_utf8Len(para) <= maxBytes) {
      pieces.add(para);
    } else {
      pieces.addAll(_chunkByBytes(para, maxBytes));
    }
  }

  final parts = <List<String>>[];
  var bucket = <String>[];
  var size = 0;
  for (final piece in pieces) {
    final len = _utf8Len(piece);
    if (bucket.isNotEmpty && size + len > maxBytes) {
      parts.add(bucket);
      bucket = <String>[];
      size = 0;
    }
    bucket.add(piece);
    size += len;
  }
  if (bucket.isNotEmpty || parts.isEmpty) parts.add(bucket);

  if (parts.length == 1) return [TxtChapter(title, parts.first)];
  return [
    for (var i = 0; i < parts.length; i++)
      TxtChapter(i == 0 ? title : '$title (${i + 1})', parts[i]),
  ];
}

List<String> _chunkByBytes(String text, int maxBytes) {
  final chunks = <String>[];
  final buffer = StringBuffer();
  var size = 0;
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    final len = _utf8Len(ch);
    if (size + len > maxBytes) {
      chunks.add(buffer.toString());
      buffer.clear();
      size = 0;
    }
    buffer.write(ch);
    size += len;
  }
  if (buffer.isNotEmpty) chunks.add(buffer.toString());
  return chunks;
}

// ───────────────────────── EPUB packing ─────────────────────────

final RegExp _xmlIllegal = RegExp(
  r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]',
);

String _xmlEscape(String s) => s
    .replaceAll(_xmlIllegal, '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Pack [chapters] into a minimal EPUB 2 (mimetype stored first and
/// uncompressed, as the OCF spec requires).
Uint8List buildEpub({
  required String title,
  required List<TxtChapter> chapters,
  required String identifier,
}) {
  final archive = Archive();

  void add(String name, String content, {bool compress = true}) {
    final data = utf8.encode(content);
    // archive 4.x has no ArchiveFile.compress setter; noCompress keeps the
    // entry stored. The mimetype entry must stay uncompressed (EPUB spec).
    final file = compress
        ? ArchiveFile(name, data.length, data)
        : ArchiveFile.noCompress(name, data.length, data);
    archive.addFile(file);
  }

  add('mimetype', 'application/epub+zip', compress: false);
  add('META-INF/container.xml', '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''');

  final manifest = StringBuffer();
  final spine = StringBuffer();
  final navPoints = StringBuffer();
  for (var i = 0; i < chapters.length; i++) {
    final id = 'ch${(i + 1).toString().padLeft(4, '0')}';
    final chapter = chapters[i];
    manifest.writeln(
      '    <item id="$id" href="$id.xhtml" media-type="application/xhtml+xml"/>',
    );
    spine.writeln('    <itemref idref="$id"/>');
    navPoints.writeln('''    <navPoint id="n$id" playOrder="${i + 1}">
      <navLabel><text>${_xmlEscape(chapter.title)}</text></navLabel>
      <content src="$id.xhtml"/>
    </navPoint>''');

    final body = StringBuffer();
    body.writeln('<h2>${_xmlEscape(chapter.title)}</h2>');
    for (final para in chapter.paragraphs) {
      body.writeln(
        '<p>${para.split('\n').map(_xmlEscape).join('<br/>')}</p>',
      );
    }
    add('OEBPS/$id.xhtml', '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh">
<head><title>${_xmlEscape(chapter.title)}</title></head>
<body>
$body</body>
</html>''');
  }

  add('OEBPS/content.opf', '''<?xml version="1.0" encoding="UTF-8"?>
<package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>${_xmlEscape(title)}</dc:title>
    <dc:language>zh</dc:language>
    <dc:identifier id="bookid">${_xmlEscape(identifier)}</dc:identifier>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
$manifest  </manifest>
  <spine toc="ncx">
$spine  </spine>
</package>''');

  add('OEBPS/toc.ncx', '''<?xml version="1.0" encoding="UTF-8"?>
<ncx version="2005-1" xmlns="http://www.daisy.org/z3986/2005/ncx/">
  <head>
    <meta name="dtb:uid" content="${_xmlEscape(identifier)}"/>
    <meta name="dtb:depth" content="1"/>
  </head>
  <docTitle><text>${_xmlEscape(title)}</text></docTitle>
  <navMap>
$navPoints  </navMap>
</ncx>''');

  final dynamic encoded = ZipEncoder().encode(archive);
  if (encoded == null) {
    throw const TxtConvertException('could not pack the EPUB');
  }
  return Uint8List.fromList((encoded as List).cast<int>());
}

// ───────────────────────── Cache key ─────────────────────────

/// FNV-1a, 64-bit, over the UTF-8 bytes of [input], as 16 hex digits.
String fnv1a64Hex(String input) {
  // Plain 64-bit wrap-around arithmetic (Dart VM ints are 64-bit).
  var hash = (0xcbf29ce4 << 32) | 0x84222325; // FNV offset basis
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = hash * 0x100000001b3; // FNV prime
  }
  String half(int v) => (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return half(hash >>> 32) + half(hash);
}

/// FNV-1a of `path | size | mtime`. Any of the three changing (the file
/// was replaced / edited) yields a new key.
String txtCacheKey(String path, int size, DateTime modified) =>
    fnv1a64Hex('$path|$size|${modified.millisecondsSinceEpoch}');

// ───────────────────────── Converter with cache ─────────────────────────

/// Converts TXT files to EPUB bytes, caching each result on disk.
class TxtToEpub {
  /// Where cached EPUBs live; injectable for tests.
  final Future<Directory> Function() _cacheDir;

  /// How many real conversions ran (cache hits do not count). Exposed
  /// so tests can prove the second open is served from the cache.
  int conversions = 0;

  TxtToEpub({Future<Directory> Function()? cacheDir})
    : _cacheDir = cacheDir ?? _defaultCacheDir;

  static Future<Directory> _defaultCacheDir() async {
    final base = await getTemporaryDirectory();
    return Directory(p.join(base.path, 'txt_epub_cache'));
  }

  /// EPUB bytes for the TXT at [path]. Throws [TxtConvertException]
  /// when the file cannot be read or decoded.
  Future<Uint8List> epubFor(String path, {String? title}) async {
    final file = File(path);
    final FileStat stat;
    try {
      stat = await file.stat();
    } catch (_) {
      throw const TxtConvertException('file not readable');
    }
    if (stat.type != FileSystemEntityType.file) {
      throw const TxtConvertException('file not found');
    }

    final key = txtCacheKey(path, stat.size, stat.modified);
    final dir = await _cacheDir();
    final cached = File(p.join(dir.path, '$key.epub'));
    try {
      if (await cached.exists()) return await cached.readAsBytes();
    } catch (_) {
      // Unreadable cache entry: reconvert below.
    }

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      throw const TxtConvertException('file not readable');
    }
    final text = decodeTxtBytes(bytes);
    if (text == null || text.trim().isEmpty) {
      throw const TxtConvertException('could not decode the text');
    }

    final bookTitle = title ?? p.basenameWithoutExtension(path);
    final chapters = splitChapters(text, fallbackTitle: bookTitle);
    final epub = buildEpub(
      title: bookTitle,
      chapters: chapters,
      identifier: 'urn:zlibx:txt:$key',
    );
    conversions++;

    try {
      await dir.create(recursive: true);
      await cached.writeAsBytes(epub, flush: true);
    } catch (_) {
      // A cache write failure must not fail the read.
    }
    return epub;
  }
}
