import 'dart:async';

import 'package:dio/dio.dart';

const downloadStallTimeout = Duration(seconds: 30);

class DownloadNoProgressException implements Exception {
  const DownloadNoProgressException();

  @override
  String toString() => 'download made no progress for 30 seconds';
}

final Object _stalled = Object();

class DownloadStallGuard {
  DownloadStallGuard._();

  static Future<T> run<T>({
    required CancelToken? parentToken,
    required Future<T> Function(
      CancelToken attemptToken,
      void Function(int received) onProgress,
    )
    body,
    Duration timeout = downloadStallTimeout,
    Timer Function(Duration duration, void Function() callback)? timerFactory,
  }) async {
    final attemptToken = CancelToken();
    final createTimer = timerFactory ?? Timer.new;
    Timer? timer;
    var lastReceived = 0;

    void rearm() {
      timer?.cancel();
      timer = createTimer(timeout, () {
        if (!attemptToken.isCancelled) attemptToken.cancel(_stalled);
      });
    }

    void onProgress(int received) {
      if (received == lastReceived) return;
      if (received < lastReceived) lastReceived = 0;
      lastReceived = received;
      rearm();
    }

    final parentCancel = parentToken?.whenCancel.then((_) {
      if (!attemptToken.isCancelled) attemptToken.cancel();
    });
    timer = createTimer(timeout, () {
      if (!attemptToken.isCancelled) attemptToken.cancel(_stalled);
    });

    try {
      return await body(attemptToken, onProgress);
    } on DioException catch (error) {
      if (identical(error.error, _stalled) &&
          !(parentToken?.isCancelled ?? false)) {
        throw const DownloadNoProgressException();
      }
      rethrow;
    } finally {
      timer?.cancel();
      if (parentToken != null && !parentToken.isCancelled) {
        unawaited(parentCancel!.then<void>((_) {}, onError: (Object _) {}));
      }
    }
  }
}
