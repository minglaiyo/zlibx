import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/providers/download_provider.dart';
import 'package:zlibx/services/resumable_downloader.dart';

/// M4: only transient transport failures retry with backoff. A content
/// error (the server answered HTML instead of a book), quota
/// exhaustion, or a user cancel never does.
void main() {
  group('isRetryableDownloadError', () {
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
  });
}
