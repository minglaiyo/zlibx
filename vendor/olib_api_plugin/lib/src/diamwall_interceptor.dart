import 'package:dio/dio.dart';

import 'diamwall_solver.dart';

class DiamWallInterceptor extends Interceptor {
  DiamWallInterceptor(this._dio);

  final Dio _dio;

  static const _retriedKey = 'zlibx.diamwall_retried';

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    if (!_canSolve(response.requestOptions, response)) {
      handler.next(response);
      return;
    }
    _solveAndRetry(response.requestOptions, response.data as String).then(
      (retried) => handler.resolve(retried ?? response),
      onError: (Object error, StackTrace stackTrace) => handler.reject(
        error is DioException
            ? error
            : DioException(
                requestOptions: response.requestOptions,
                error: error,
                stackTrace: stackTrace,
              ),
      ),
    );
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final response = err.response;
    if (response == null || !_canSolve(err.requestOptions, response)) {
      handler.next(err);
      return;
    }
    _solveAndRetry(err.requestOptions, response.data.toString()).then(
      (retried) {
        if (retried != null) {
          handler.resolve(retried);
        } else {
          handler.next(err);
        }
      },
      onError: (Object retryError, StackTrace stackTrace) => handler.reject(
        retryError is DioException
            ? retryError
            : DioException(
                requestOptions: err.requestOptions,
                error: retryError,
                stackTrace: stackTrace,
              ),
      ),
    );
  }

  bool _canSolve(RequestOptions options, Response<dynamic> response) {
    final uri = options.uri;
    return uri.scheme == 'https' &&
        response.statusCode == 503 &&
        options.extra[_retriedKey] != true &&
        response.data is String &&
        DiamWallSolver.looksLikeChallenge(503, response.data as String);
  }

  Future<Response<dynamic>?> _solveAndRetry(
    RequestOptions options,
    String html,
  ) async {
    try {
      final cookies = await DiamWallSolver.solve(html);
      if (cookies == null || (options.cancelToken?.isCancelled ?? false)) {
        return null;
      }
      final existingCookie = options.headers.entries
          .firstWhere(
            (entry) => entry.key.toLowerCase() == 'cookie',
            orElse: () => const MapEntry('', null),
          )
          .value
          ?.toString();
      final headers = Map<String, dynamic>.from(options.headers)
        ..removeWhere((key, _) => key.toLowerCase() == 'cookie');
      headers['Cookie'] = [
        if (existingCookie != null && existingCookie.isNotEmpty) existingCookie,
        ...cookies.entries.map((entry) => '${entry.key}=${entry.value}'),
      ].join('; ');
      return await _dio.fetch<dynamic>(
        options.copyWith(
          headers: headers,
          extra: {...options.extra, _retriedKey: true},
        ),
      );
    } on DioException {
      rethrow;
    } catch (error, stackTrace) {
      throw DioException(
        requestOptions: options,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
