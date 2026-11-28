// A streaming ZIP writer for the LAN web service's "pack everything"
// download (/zip/all).
//
// The old implementation read every book into memory, built an
// `Archive` and ran `ZipEncoder().encode` — peak memory was the whole
// library (twice), which kills the app on a phone as soon as the shelf
// holds a few hundred MB, and nothing was sent until all of it was
// done. This writer instead:
//
//  * STOREs the files (method 0). Books (epub / pdf / mobi / cbz) are
//    already compressed, so deflate only burns CPU and battery;
//  * pulls each file from disk in 64 KB chunks and hands every chunk
//    to the socket as it is read (memory stays ~constant, the browser
//    starts saving at once);
//  * knows the exact output length up front ([length]) because STORE
//    makes every size predictable, so the browser can show a real
//    progress bar / ETA instead of "unknown size";
//  * writes the CRC-32 in a trailing data descriptor (flag bit 3) so
//    the files never have to be read twice. The real sizes are ALSO
//    put in the local header, which is what strict streaming readers
//    (Java's ZipInputStream on STORED entries) need;
//  * switches an entry to ZIP64 when it is >= 4 GiB, and writes ZIP64
//    end-of-central-directory records when the archive needs them.
//
// If a file changes length while it is being packed the stream throws
// instead of emitting a silently corrupt archive: the connection is
// aborted and the browser reports a failed download.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One file to pack. [size] and [modified] are taken when the plan is
/// made; [StreamingZip.length] is computed from them.
class ZipPlanEntry {
  /// The entry name inside the archive (already path-safe).
  final String name;

  /// The real file on disk.
  final String path;

  final int size;
  final DateTime modified;

  const ZipPlanEntry({
    required this.name,
    required this.path,
    required this.size,
    required this.modified,
  });
}

class _Laid {
  final ZipPlanEntry entry;
  final Uint8List nameBytes;
  final int offset;
  final bool bigSize;
  final bool bigOffset;
  final int localHeaderLength;

  const _Laid({
    required this.entry,
    required this.nameBytes,
    required this.offset,
    required this.bigSize,
    required this.bigOffset,
    required this.localHeaderLength,
  });

  int get descriptorLength => bigSize ? 24 : 16;

  int get centralExtraLength {
    final fields = (bigSize ? 16 : 0) + (bigOffset ? 8 : 0);
    return fields == 0 ? 0 : fields + 4;
  }

  int get centralLength => 46 + nameBytes.length + centralExtraLength;
}

class StreamingZip {
  static const int _u32 = 0xFFFFFFFF;
  static const int _u16 = 0xFFFF;

  final List<ZipPlanEntry> entries;
  final int _zip64Threshold;

  late final List<_Laid> _laid;
  late final int _centralOffset;
  late final int _centralSize;
  late final bool _needZip64End;

  /// Exact number of bytes [stream] will produce.
  late final int length;

  /// [zip64Threshold] is the size from which an entry (or an offset)
  /// is written ZIP64. It is 0xFFFFFFFF by the spec; tests lower it to
  /// exercise the ZIP64 path with tiny files.
  StreamingZip(this.entries, {int zip64Threshold = _u32})
    : _zip64Threshold = zip64Threshold {
    final laid = <_Laid>[];
    var offset = 0;
    for (final e in entries) {
      final nameBytes = Uint8List.fromList(utf8.encode(e.name));
      final bigSize = e.size >= _zip64Threshold;
      final bigOffset = offset >= _zip64Threshold;
      final local = 30 + nameBytes.length + (bigSize ? 20 : 0);
      final item = _Laid(
        entry: e,
        nameBytes: nameBytes,
        offset: offset,
        bigSize: bigSize,
        bigOffset: bigOffset,
        localHeaderLength: local,
      );
      laid.add(item);
      offset += local + e.size + item.descriptorLength;
    }
    _laid = laid;
    _centralOffset = offset;
    _centralSize = laid.fold<int>(0, (sum, l) => sum + l.centralLength);
    _needZip64End =
        laid.length >= _u16 ||
        _centralOffset >= _zip64Threshold ||
        _centralSize >= _zip64Threshold;
    length = _centralOffset + _centralSize + (_needZip64End ? 56 + 20 : 0) + 22;
  }

  // ── CRC-32 (IEEE) ────────────────────────────────────────────────

  static final Uint32List _crcTable = () {
    final table = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[n] = c;
    }
    return table;
  }();

  /// Running CRC-32 over [data]. Start from 0xFFFFFFFF and XOR the
  /// final value with 0xFFFFFFFF.
  static int crcUpdate(int crc, List<int> data) {
    final table = _crcTable;
    var c = crc;
    for (var i = 0; i < data.length; i++) {
      c = table[(c ^ data[i]) & 0xFF] ^ (c >>> 8);
    }
    return c;
  }

  /// CRC-32 of [data] in one go (for tests and small inputs).
  static int crc32(List<int> data) => crcUpdate(0xFFFFFFFF, data) ^ 0xFFFFFFFF;

  // ── DOS date / time ──────────────────────────────────────────────

  static int _dosTime(DateTime t) =>
      (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2);

  static int _dosDate(DateTime t) {
    final year = (t.year - 1980).clamp(0, 127);
    return (year << 9) | (t.month << 5) | t.day;
  }

  // ── Records ──────────────────────────────────────────────────────

  Uint8List _localHeader(_Laid l) {
    final e = l.entry;
    final b = ByteData(l.localHeaderLength);
    b.setUint32(0, 0x04034b50, Endian.little);
    b.setUint16(4, l.bigSize ? 45 : 20, Endian.little); // version needed
    b.setUint16(6, 0x0808, Endian.little); // data descriptor + UTF-8 names
    b.setUint16(8, 0, Endian.little); // STORE
    b.setUint16(10, _dosTime(e.modified), Endian.little);
    b.setUint16(12, _dosDate(e.modified), Endian.little);
    b.setUint32(14, 0, Endian.little); // crc: in the descriptor
    b.setUint32(18, l.bigSize ? _u32 : e.size, Endian.little);
    b.setUint32(22, l.bigSize ? _u32 : e.size, Endian.little);
    b.setUint16(26, l.nameBytes.length, Endian.little);
    b.setUint16(28, l.bigSize ? 20 : 0, Endian.little);
    final out = b.buffer.asUint8List();
    out.setRange(30, 30 + l.nameBytes.length, l.nameBytes);
    if (l.bigSize) {
      final x = 30 + l.nameBytes.length;
      b.setUint16(x, 1, Endian.little); // ZIP64 extra
      b.setUint16(x + 2, 16, Endian.little);
      b.setUint64(x + 4, e.size, Endian.little); // uncompressed
      b.setUint64(x + 12, e.size, Endian.little); // compressed
    }
    return out;
  }

  Uint8List _descriptor(_Laid l, int crc) {
    final b = ByteData(l.descriptorLength);
    b.setUint32(0, 0x08074b50, Endian.little);
    b.setUint32(4, crc, Endian.little);
    if (l.bigSize) {
      b.setUint64(8, l.entry.size, Endian.little);
      b.setUint64(16, l.entry.size, Endian.little);
    } else {
      b.setUint32(8, l.entry.size, Endian.little);
      b.setUint32(12, l.entry.size, Endian.little);
    }
    return b.buffer.asUint8List();
  }

  Uint8List _centralHeader(_Laid l, int crc) {
    final e = l.entry;
    final zip64 = l.bigSize || l.bigOffset;
    final b = ByteData(l.centralLength);
    b.setUint32(0, 0x02014b50, Endian.little);
    b.setUint16(4, (3 << 8) | (zip64 ? 45 : 20), Endian.little); // unix host
    b.setUint16(6, zip64 ? 45 : 20, Endian.little);
    b.setUint16(8, 0x0808, Endian.little);
    b.setUint16(10, 0, Endian.little);
    b.setUint16(12, _dosTime(e.modified), Endian.little);
    b.setUint16(14, _dosDate(e.modified), Endian.little);
    b.setUint32(16, crc, Endian.little);
    b.setUint32(20, l.bigSize ? _u32 : e.size, Endian.little);
    b.setUint32(24, l.bigSize ? _u32 : e.size, Endian.little);
    b.setUint16(28, l.nameBytes.length, Endian.little);
    b.setUint16(30, l.centralExtraLength, Endian.little);
    b.setUint16(32, 0, Endian.little); // comment length
    b.setUint16(34, 0, Endian.little); // disk number
    b.setUint16(36, 0, Endian.little); // internal attributes
    b.setUint32(38, 0x81A40000, Endian.little); // regular file, 0644
    b.setUint32(42, l.bigOffset ? _u32 : l.offset, Endian.little);
    final out = b.buffer.asUint8List();
    out.setRange(46, 46 + l.nameBytes.length, l.nameBytes);
    if (l.centralExtraLength > 0) {
      var x = 46 + l.nameBytes.length;
      b.setUint16(x, 1, Endian.little);
      b.setUint16(x + 2, l.centralExtraLength - 4, Endian.little);
      x += 4;
      if (l.bigSize) {
        b.setUint64(x, e.size, Endian.little);
        b.setUint64(x + 8, e.size, Endian.little);
        x += 16;
      }
      if (l.bigOffset) {
        b.setUint64(x, l.offset, Endian.little);
      }
    }
    return out;
  }

  Uint8List _end() {
    final count = _laid.length;
    final needs = _needZip64End;
    final b = ByteData((needs ? 56 + 20 : 0) + 22);
    var x = 0;
    if (needs) {
      final zip64EndOffset = _centralOffset + _centralSize;
      b.setUint32(x, 0x06064b50, Endian.little);
      b.setUint64(x + 4, 44, Endian.little); // size of the rest
      b.setUint16(x + 12, (3 << 8) | 45, Endian.little);
      b.setUint16(x + 14, 45, Endian.little);
      b.setUint32(x + 16, 0, Endian.little);
      b.setUint32(x + 20, 0, Endian.little);
      b.setUint64(x + 24, count, Endian.little);
      b.setUint64(x + 32, count, Endian.little);
      b.setUint64(x + 40, _centralSize, Endian.little);
      b.setUint64(x + 48, _centralOffset, Endian.little);
      x += 56;
      b.setUint32(x, 0x07064b50, Endian.little); // locator
      b.setUint32(x + 4, 0, Endian.little);
      b.setUint64(x + 8, zip64EndOffset, Endian.little);
      b.setUint32(x + 16, 1, Endian.little);
      x += 20;
    }
    b.setUint32(x, 0x06054b50, Endian.little);
    b.setUint16(x + 4, 0, Endian.little);
    b.setUint16(x + 6, 0, Endian.little);
    b.setUint16(x + 8, needs ? _u16 : count, Endian.little);
    b.setUint16(x + 10, needs ? _u16 : count, Endian.little);
    b.setUint32(x + 12, needs ? _u32 : _centralSize, Endian.little);
    b.setUint32(x + 16, needs ? _u32 : _centralOffset, Endian.little);
    b.setUint16(x + 20, 0, Endian.little);
    return b.buffer.asUint8List();
  }

  /// The archive, produced lazily and in order. Back-pressure from
  /// the consumer (the socket) pauses the file reads.
  Stream<List<int>> stream() async* {
    final crcs = <int>[];
    for (final l in _laid) {
      yield _localHeader(l);
      var crc = 0xFFFFFFFF;
      var count = 0;
      if (l.entry.size > 0) {
        await for (final chunk in File(
          l.entry.path,
        ).openRead(0, l.entry.size)) {
          crc = crcUpdate(crc, chunk);
          count += chunk.length;
          yield chunk;
        }
      }
      if (count != l.entry.size) {
        // The file shrank or vanished mid-download. Abort: a short
        // archive that claims a longer Content-Length is detected by
        // the client, a silently wrong one would not be.
        throw FileSystemException(
          'file changed while it was being packed',
          l.entry.path,
        );
      }
      final finalCrc = (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
      crcs.add(finalCrc);
      yield _descriptor(l, finalCrc);
    }
    for (var i = 0; i < _laid.length; i++) {
      yield _centralHeader(_laid[i], crcs[i]);
    }
    yield _end();
  }
}
