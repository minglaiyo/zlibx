import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

void main() {
  final challenge = File(
    'test/fixtures/diamwall_challenge.html',
  ).readAsStringSync();

  test('extracts the seed from the captured challenge', () {
    expect(
      DiamWallSolver.extractSeed(challenge),
      '41422B673A3F3952CFB782FA36EDD50B03028CCD',
    );
  });

  test('solves the captured proof-of-work with the expected nonce', () {
    final cookies = DiamWallSolver.solveSync(challenge);

    expect(cookies, isNotNull);
    expect(cookies!['c_token'], '41422B673A3F3952CFB782FA36EDD50B03028CCD9783');
    expect(double.parse(cookies['c_time']!), greaterThanOrEqualTo(0));
  });

  test('solved token satisfies the embedded digest check', () {
    final cookies = DiamWallSolver.solveSync(challenge)!;
    final token = cookies['c_token']!;
    final seed = token.substring(0, 40);
    final n1 = int.parse(seed[0], radix: 16);
    final digest = crypto.sha1.convert(token.codeUnits).bytes;

    expect(digest[n1], 0xB0);
    expect(digest[n1 + 1], 0x0B);
  });

  test('isolate solve returns the same deterministic token', () async {
    final cookies = await DiamWallSolver.solve(challenge);

    expect(cookies?['c_token'], '41422B673A3F3952CFB782FA36EDD50B03028CCD9783');
  });

  test('accepts lowercase and double-quoted seed arrays', () {
    final html = challenge
        .replaceAll(
          "'41422B673A3F3952CFB782FA36EDD50B03028CCD'",
          '"41422b673a3f3952cfb782fa36edd50b03028ccd"',
        )
        .replaceAll("'c_token='", '"c_token="');

    expect(
      DiamWallSolver.solveSync(html)?['c_token'],
      '41422b673a3f3952cfb782fa36edd50b03028ccd106466',
    );
  });

  test('recognizes 503 and cached challenge bodies only with a seed', () {
    expect(DiamWallSolver.looksLikeChallenge(503, challenge), isTrue);
    expect(DiamWallSolver.looksLikeChallenge(200, challenge), isTrue);
    expect(
      DiamWallSolver.looksLikeChallenge(503, '<h1>Unavailable</h1>'),
      isFalse,
    );
    expect(DiamWallSolver.looksLikeChallenge(200, '<h1>Results</h1>'), isFalse);
  });

  test('rejects missing or malformed seeds', () {
    expect(DiamWallSolver.solveSync('<html>no challenge</html>'), isNull);
    expect(
      DiamWallSolver.solveSync(
        '''<title>Checking your browser</title><script>const a=['FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF','c_token='];</script>''',
      ),
      isNull,
    );
  });
}
