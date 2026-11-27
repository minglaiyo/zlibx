import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/download_provider.dart';
import 'package:zlibx/services/download_stall_guard.dart';
import 'package:zlibx/services/resumable_downloader.dart';

/// M4: only transient transport failures retry with backoff. A content
/// error (the server answered HTML instead of a book), quota
/// exhaustion, or a user cancel never does.
void main() {
  group('downloadRetryDelays', () {
    test('plan item 10: exponential backoff, at most 3 retries', () {
      expect(
        downloadRetryDelays,
        const [
          Duration(seconds: 2),
          Duration(seconds: 4),
          Duration(seconds: 8),
        ],
      );
    });
  });

  group('isRetryableDownloadError', () {
    test('no-progress watchdog failures retry', () {
      expect(
        isRetryableDownloadError(const DownloadNoProgressException()),
        isTrue,
      );
    });

    test('connection errors retry', () {
      expect(
        isRetryableDownloadError(
          DioException(
            requestOptions: RequestOptions(path: 'https://example.com'),
            type: DioExceptionType.connectionError,
          ),
        ),
        isTrue,
      );
    });

    test('5xx answers retry, 4xx do not', () {
      for (final status in [500, 502, 503]) {
        expect(
          isRetryableDownloadError(
            DioException(
              requestOptions: RequestOptions(path: 'https://example.com'),
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions:
                    RequestOptions(path: 'https://example.com'),
                statusCode: status,
              ),
            ),
          ),
          isTrue,
        );
      }
      expect(
        isRetryableDownloadError(
          DioException(
            requestOptions: RequestOptions(path: 'https://example.com'),
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: RequestOptions(path: 'https://example.com'),
              statusCode: 404,
            ),
          ),
        ),
        isFalse,
      );
    });

    test('truncations retry (both engines)', () {
      expect(
        isRetryableDownloadError(
          const DownloadTruncatedException(10, 100),
        ),
        isTrue,
      );
      // The vendor plugin reports the same truncation as a StateError
      // with a fixed message prefix.
      expect(
        isRetryableDownloadError(
          StateError('download truncated: received 10 of 100 bytes'),
        ),
        isTrue,
      );
    });

    test('content errors and other StateErrors never retry', () {
      expect(
        isRetryableDownloadError(
          const DownloadContentException('download body is an HTML page'),
        ),
        isFalse,
      );
      expect(
        isRetryableDownloadError(
          StateError('too many download redirects'),
        ),
        isFalse,
      );
    });

    test('plan item 10: a 5xx carrying a refusal text does not retry', () {
      // The table decides the 5xx branch: a 500 that says
      // "Access denied" is a refused request, not a transient error.
      for (final body in [
        {'error': 'Access denied'},
        'Access denied',
      ]) {
        expect(
          isRetryableDownloadError(
            DioException(
              requestOptions: RequestOptions(path: 'https://example.com'),
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions:
                    RequestOptions(path: 'https://example.com'),
                statusCode: 500,
                data: body,
              ),
            ),
          ),
          isFalse,
        );
      }
    });

    test('plan item 10: magic mismatches and quota never retry', () {
      expect(
        isRetryableDownloadError(
          const DownloadMagicException('wrong file header'),
        ),
        isFalse,
      );
      expect(
        isRetryableDownloadError(
          const DownloadHtmlException('download body is an HTML page'),
        ),
        isFalse,
      );
      expect(
        isRetryableDownloadError(const DownloadLimitReachedException()),
        isFalse,
      );
    });

    test('plan item 10: other 4xx and ordinary cancellation never retry', () {
      for (final status in [400, 401, 403, 429]) {
        expect(
          isRetryableDownloadError(
            DioException(
              requestOptions: RequestOptions(path: 'https://example.com'),
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions:
                    RequestOptions(path: 'https://example.com'),
                statusCode: status,
              ),
            ),
          ),
          isFalse,
          reason: 'HTTP $status',
        );
      }
      expect(
        isRetryableDownloadError(
          DioException(
            requestOptions: RequestOptions(path: 'https://example.com'),
            type: DioExceptionType.cancel,
          ),
        ),
        isFalse,
      );
    });

    test('connection, receive, and send timeouts retry', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
      ]) {
        expect(
          isRetryableDownloadError(
            DioException(
              requestOptions: RequestOptions(path: 'https://example.com'),
              type: type,
            ),
          ),
          isTrue,
          reason: '$type',
        );
      }
    });
  });
}
