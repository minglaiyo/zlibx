import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';

// Plan item 10: the error table. Pure unit tests — no network, no
// adapter. The table's contract: message rules before status rules,
// a refused request is never a session verdict, and nothing retries
// except a 5xx.
void main() {
  group('classifyZlibError', () {
    test('Access denied is a refusal, never a session verdict', () {
      expect(
        classifyZlibError(message: 'Access denied'),
        ZlibErrorKind.searchRefused,
      );
      expect(
        classifyZlibError(message: 'HTTP 400: Access denied'),
        ZlibErrorKind.searchRefused,
      );
      expect(
        classifyZlibError(status: 403, message: 'Access denied'),
        ZlibErrorKind.searchRefused,
      );
      expect(
        classifyZlibError(message: '拒绝访问'),
        ZlibErrorKind.searchRefused,
      );
      // Message rules win over status rules: a 500 that says
      // "Access denied" is still a refusal, not a retryable server
      // error.
      expect(
        classifyZlibError(status: 500, message: 'Access denied'),
        ZlibErrorKind.searchRefused,
      );
    });

    test('daily limit is quota', () {
      expect(
        classifyZlibError(message: 'daily limit reached'),
        ZlibErrorKind.quotaExhausted,
      );
      expect(
        classifyZlibError(message: 'Daily Limit exceeded'),
        ZlibErrorKind.quotaExhausted,
      );
    });

    test('invalid credentials / please login expire the session', () {
      expect(
        classifyZlibError(message: 'invalid credentials'),
        ZlibErrorKind.sessionExpired,
      );
      expect(
        classifyZlibError(message: 'please login'),
        ZlibErrorKind.sessionExpired,
      );
      expect(
        classifyZlibError(message: 'please log in'),
        ZlibErrorKind.sessionExpired,
      );
      expect(
        classifyZlibError(message: 'invalid token'),
        ZlibErrorKind.sessionExpired,
      );
      expect(
        classifyZlibError(message: 'login required'),
        ZlibErrorKind.sessionExpired,
      );
    });

    test('wrong credentials are a credential error, not a session verdict',
        () {
      expect(
        classifyZlibError(message: 'incorrect email or password'),
        ZlibErrorKind.credentialError,
      );
      expect(
        classifyZlibError(message: 'authorization failed'),
        ZlibErrorKind.credentialError,
      );
    });

    test('the not-a-rejection guard wins over session words', () {
      expect(
        classifyZlibError(message: 'too many requests, try again'),
        ZlibErrorKind.unknown,
      );
      expect(
        classifyZlibError(message: 'slow down, your session expired'),
        ZlibErrorKind.unknown,
      );
    });

    test('513 / 517 / DiamWall mean switch lines', () {
      expect(
        classifyZlibError(status: 513),
        ZlibErrorKind.switchDomain,
      );
      expect(
        classifyZlibError(status: 517),
        ZlibErrorKind.switchDomain,
      );
      expect(
        classifyZlibError(message: '__diamwall=abc'),
        ZlibErrorKind.switchDomain,
      );
      // The status may only be inside the message text.
      expect(
        classifyZlibError(message: 'HTTP 513: blocked'),
        ZlibErrorKind.switchDomain,
      );
    });

    test('5xx retries, other 4xx does not', () {
      for (final code in [500, 502, 503, 504]) {
        expect(
          classifyZlibError(status: code),
          ZlibErrorKind.serverRetryable,
          reason: 'HTTP $code',
        );
      }
      expect(
        classifyZlibError(message: 'HTTP 503: Service Unavailable'),
        ZlibErrorKind.serverRetryable,
      );
      for (final code in [400, 401, 404, 429]) {
        expect(
          classifyZlibError(status: code),
          ZlibErrorKind.clientError,
          reason: 'HTTP $code',
        );
      }
      expect(
        classifyZlibError(message: 'HTTP 404: not found'),
        ZlibErrorKind.clientError,
      );
    });

    test('nothing matching is unknown, never a guess', () {
      expect(classifyZlibError(message: 'something else'), ZlibErrorKind.unknown);
      expect(classifyZlibError(message: ''), ZlibErrorKind.unknown);
      expect(classifyZlibError(), ZlibErrorKind.unknown);
    });
  });

  group('zlibErrorText', () {
    test('a plain string passes through', () {
      expect(zlibErrorText('Access denied'), 'Access denied');
    });

    test('an envelope yields its error / message field', () {
      expect(
        zlibErrorText({'error': 'Access denied'}),
        'Access denied',
      );
      expect(
        zlibErrorText({'message': 'daily limit'}),
        'daily limit',
      );
      expect(zlibErrorText({'success': 0}), '');
      expect(zlibErrorText({'error': 513}), '513');
    });

    test('a DioException yields its response body, else its message', () {
      final withBody = DioException(
        requestOptions: RequestOptions(path: '/eapi/user/profile'),
        response: Response(
          requestOptions: RequestOptions(path: '/eapi/user/profile'),
          statusCode: 400,
          data: {'error': 'Access denied'},
        ),
      );
      expect(zlibErrorText(withBody), 'Access denied');

      final withMessage = DioException(
        requestOptions: RequestOptions(path: '/x'),
        message: 'connection error: host unreachable',
      );
      expect(zlibErrorText(withMessage), 'connection error: host unreachable');
    });

    test('null and other objects', () {
      expect(zlibErrorText(null), '');
      expect(zlibErrorText(42), '42');
    });
  });

  group('rejectsSessionMessage delegates to the table', () {
    test('a refusal never blames the session', () {
      expect(ZLibraryApiBase.rejectsSessionMessage('Access denied'), isFalse);
      expect(ZLibraryApiBase.rejectsSessionMessage('拒绝访问'), isFalse);
    });

    test('new session words count', () {
      expect(
        ZLibraryApiBase.rejectsSessionMessage('invalid credentials'),
        isTrue,
      );
      expect(
        ZLibraryApiBase.rejectsSessionMessage('please login'),
        isTrue,
      );
    });

    test('a credential error never blames the session', () {
      expect(
        ZLibraryApiBase.rejectsSessionMessage(
          'incorrect email or password',
        ),
        isFalse,
      );
      expect(
        ZLibraryApiBase.rejectsSessionMessage('authorization failed'),
        isFalse,
      );
    });

    test('the guard still wins', () {
      expect(
        ZLibraryApiBase.rejectsSessionMessage('too many requests'),
        isFalse,
      );
      expect(ZLibraryApiBase.rejectsSessionMessage(null), isFalse);
    });
  });
}
