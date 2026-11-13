import 'dart:async';

/// A FIFO semaphore bounding how many downloads run at once (S6).
///
/// At most [maxConcurrent] downloads hold a slot; further callers wait
/// (in start order) until one frees. Each download can buffer up to
/// 8 MB in memory, so an unbounded burst stalls the UI thread on weak
/// devices and gets the process reaped sooner in the background. The
/// wait never blocks the UI: callers fire `startDownload` with
/// `unawaited`, and the task shows as `pending` while queued.
class DownloadSlotPool {
  /// Max simultaneous downloads (S6: the review suggests 2–3).
  final int maxConcurrent;

  int _active = 0;
  final List<Completer<void>> _waiters = [];

  DownloadSlotPool({this.maxConcurrent = 3});

  /// Downloads currently holding a slot (for tests / diagnostics).
  int get activeCount => _active;

  /// Downloads waiting for a slot.
  int get waitingCount => _waiters.length;

  /// Acquires a slot, waiting (FIFO) if all [maxConcurrent] are busy.
  Future<void> acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  /// Frees a slot and wakes the next waiter (FIFO). Safe to call even
  /// if no slot is held: a double release cannot drive the count
  /// negative and stall the queue.
  void release() {
    if (_active > 0) _active--;
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeAt(0);
      if (!next.isCompleted) {
        _active++;
        next.complete();
        return;
      }
    }
  }
}
