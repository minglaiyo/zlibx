// StreamingZip: exact length, valid archives, ZIP64 path, CRC-32.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/services/streaming_zip.dart';

Future<Uint8List> _collect(Stream<List<int>> s) async {
  final b = BytesBuilder(copy: false);
  await for (final c in s) {
    b.add(c);
  }
  return b.takeBytes();
}

void main() {
  late Directory tmp;
  late List<ZipPlanEntry> plan;
  late Map<String, List<int>> contents;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('streaming_zip_test');
    contents = {
      'a.epub': List<int>.generate(200000, (i) => (i * 31) & 0xFF),
      '中文 书名 - 作者.pdf': List<int>.generate(70000, (i) => (i * 7) & 0xFF),
      'empty.txt': <int>[],
      'one.mobi': <int>[42],
    };
    plan = [];
    var n = 0;
    contents.forEach((name, data) {
      final f = File('${tmp.path}/f${n++}')..writeAsBytesSync(data);
      plan.add(
        ZipPlanEntry(
          name: name,
          path: f.path,
          size: data.length,
          modified: f.statSync().modified,
        ),
      );
    });
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  void expectValid(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    expect(archive.files.map((f) => f.name), contents.keys);
    for (final f in archive.files) {
      expect(f.content as List<int>, contents[f.name], reason: f.name);
    }
  }

  test('CRC-32 matches the standard check value', () {
    expect(StreamingZip.crc32('123456789'.codeUnits), 0xCBF43926);
    expect(StreamingZip.crc32(const <int>[]), 0);
    // Chunked == whole.
    final data = List<int>.generate(100000, (i) => i & 0xFF);
    var crc = 0xFFFFFFFF;
    for (var i = 0; i < data.length; i += 65536) {
      crc = StreamingZip.crcUpdate(
        crc,
        data.sublist(i, (i + 65536).clamp(0, data.length)),
      );
    }
    expect(crc ^ 0xFFFFFFFF, StreamingZip.crc32(data));
  });

  test('length is exact and the archive is valid', () async {
    final zip = StreamingZip(plan);
    final bytes = await _collect(zip.stream());
    expect(bytes.length, zip.length);
    expectValid(bytes);
  });

  test('the ZIP64 paths (entry sizes, offsets, end records) stay valid', () async {
    // Lower the threshold so tiny files take every ZIP64 branch.
    for (final threshold in [1, 1000, 100000]) {
      final zip = StreamingZip(plan, zip64Threshold: threshold);
      final bytes = await _collect(zip.stream());
      expect(bytes.length, zip.length, reason: 'threshold $threshold');
      expectValid(bytes);
    }
  });

  test('a file that shrinks while packing aborts instead of corrupting', () async {
    final zip = StreamingZip(plan);
    File(plan.first.path).writeAsBytesSync([1, 2, 3]);
    await expectLater(_collect(zip.stream()), throwsA(isA<FileSystemException>()));
  });
}
