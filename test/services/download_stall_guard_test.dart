import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/providers/download_provider.dart';
import 'package:zlibx/services/download_stall_guard.dart';

class _ManualTimer implements Timer {
  _ManualTimer(this.callback);

  final void Function() callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    callback();
  }
}

DioException _cancelled(Object? reason) => DioException(
  requestOptions: RequestOptions(path: 'https://example.com'),
  type: DioExceptionType.cancel,
  error: reason,
);

void main() {
  test('no progress cancels only the attempt and becomes retryable', () async {
    final parent = CancelToken();
    final timers = <_ManualTimer>[];
    late CancelToken attempt;
    final failure = Completer<DioException>();
    final future = DownloadStallGuard.run<void>(
      parentToken: parent,
      timerFactory: (_, callback) {
        final timer = _ManualTimer(callback);
        timers.add(timer);
        return timer;
      },
      body: (token, _) {
        attempt = token;
        token.whenCancel.then((error) {
          failure.completeError(_cancelled(error.error));
        });
        return failure.future;
      },
    );

    timers.single.fire();
    await expectLater(future, throwsA(isA<DownloadNoProgressException>()));
    expect(parent.isCancelled, isFalse);
    expect(attempt.isCancelled, isTrue);
    expect(
      isRetryableDownloadError(const DownloadNoProgressException()),
      isTrue,
    );
    expect(timers.single.isActive, isFalse);
  });

  test(
    'positive progress rearms the watchdog and duplicate reports do not',
    () async {
      final timers = <_ManualTimer>[];
      final done = Completer<void>();
      final future = DownloadStallGuard.run<void>(
        parentToken: null,
        timerFactory: (_, callback) {
          final timer = _ManualTimer(callback);
          timers.add(timer);
          return timer;
        },
        body: (_, onProgress) async {
          onProgress(1024);
          timers[0].fire();
          onProgress(1024);
          onProgress(2048);
          timers[1].fire();
          onProgress(512);
          timers.last.fire();
          done.complete();
        },
      );

      await future;
      await done.future;
      expect(timers, hasLength(4));
      expect(timers[0].isActive, isFalse);
      expect(timers[1].isActive, isFalse);
      expect(timers[2].isActive, isFalse);
      expect(timers[3].isActive, isFalse);
    },
  );

  test(
    'parent cancellation stays an ordinary non-retryable cancellation',
    () async {
      final parent = CancelToken();
      final future = DownloadStallGuard.run<void>(
        parentToken: parent,
        body: (token, _) async {
          await token.whenCancel;
          throw _cancelled(null);
        },
      );

      parent.cancel();
      await expectLater(future, throwsA(isA<DioException>()));
      expect(isRetryableDownloadError(_cancelled(null)), isFalse);
    },
  );

  test('parent cancellation wins a timeout race', () async {
    final parent = CancelToken();
    _ManualTimer? timer;
    final future = DownloadStallGuard.run<void>(
      parentToken: parent,
      timerFactory: (_, callback) => timer = _ManualTimer(callback),
      body: (token, _) async {
        await token.whenCancel;
        throw _cancelled(token.cancelError?.error);
      },
    );

    timer!.fire();
    parent.cancel();
    await expectLater(future, throwsA(isA<DioException>()));
  });
}
