import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

// Algorithm and challenge format adapted from warreth/OpenlibExtended (AGPL-3.0).
class DiamWallSolver {
  DiamWallSolver._();

  static const maxIterations = 1 << 20;
  static const _digestByteLength = 20;
  static const _titleMarker = 'checking your browser';
  static final _seedPattern = RegExp(
    r"""(['"])([0-9a-fA-F]{40})\1\s*,\s*(['"])c_token=\3""",
  );

  static bool looksLikeChallenge(int? statusCode, String html) {
    if (statusCode != 503 && !html.toLowerCase().contains(_titleMarker)) {
      return false;
    }
    return extractSeed(html) != null;
  }

  static String? extractSeed(String html) =>
      _seedPattern.firstMatch(html)?.group(2);

  static Future<Map<String, String>?> solve(String html) =>
      Isolate.run(() => solveSync(html));

  static Map<String, String>? solveSync(String html) {
    final seed = extractSeed(html);
    if (seed == null) return null;

    final n1 = int.tryParse(seed[0], radix: 16) ?? -1;
    if (n1 < 0 || n1 + 1 >= _digestByteLength) return null;

    final stopwatch = Stopwatch()..start();
    final input = Uint8List(47)..setRange(0, 40, seed.codeUnits);
    for (var i = 0; i <= maxIterations; i++) {
      final counter = i.toString().codeUnits;
      input.setRange(40, 40 + counter.length, counter);
      final length = 40 + counter.length;
      final digest = crypto.sha1
          .convert(Uint8List.view(input.buffer, 0, length))
          .bytes;
      if (digest[n1] == 0xB0 && digest[n1 + 1] == 0x0B) {
        stopwatch.stop();
        return {
          'c_token': '$seed$i',
          'c_time':
              (stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond)
                  .toString(),
        };
      }
    }
    return null;
  }
}
