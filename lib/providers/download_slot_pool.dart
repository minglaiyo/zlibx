import 'dart:async';

/// A FIFO semaphore bounding how many downloads run at once (S6).
///
/// At most [maxConcurrent] downloads hold a slot; further callers wait
/// (in start order) until one frees. Each download can buffer up to
/// 8 MB in memory, so an unbounded burst stalls the UI thread on weak
/// devices and gets the process reaped sooner in the background. The
/// wait never blocks the UI: callers fire `startDownload` with
/// `unawaited`, and the task shows as `pending` while queued.
///
/// 等待者带 key（下载任务的 bookId）：下载页的「置顶」（E2）把某个
/// pending 任务挪到队首，靠 [prioritize] 在这个队列里插队——先拿到
/// 槽位的是置顶的那本。
class DownloadSlotPool {
  /// Max simultaneous downloads (S6: the review suggests 2–3).
  final int maxConcurrent;

  int _active = 0;
  final List<({String? key, Completer<void> completer})> _waiters = [];

  DownloadSlotPool({this.maxConcurrent = 3});

  /// Downloads currently holding a slot (for tests / diagnostics).
  int get activeCount => _active;

  /// Downloads waiting for a slot.
  int get waitingCount => _waiters.length;

  /// Acquires a slot, waiting (FIFO) if all [maxConcurrent] are busy.
  /// [key] marks the waiter so [prioritize] can find it; a keyless
  /// acquire keeps plain FIFO semantics (tests).
  Future<void> acquire({String? key}) {
    if (_active < maxConcurrent) {
      _active++;
      return Future.value();
    }
    final waiter = Completer<void>();
    _waiters.add((key: key, completer: waiter));
    return waiter.future;
  }

  /// Frees a slot and wakes the next waiter (FIFO). Safe to call even
  /// if no slot is held: a double release cannot drive the count
  /// negative and stall the queue.
  void release() {
    if (_active > 0) _active--;
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeAt(0);
      if (!next.completer.isCompleted) {
        _active++;
        next.completer.complete();
        return;
      }
    }
  }

  /// 把 key 对应的等待者挪到队首（下载页「置顶」，E2）。没在排队
  /// （已经在下载、槽位空闲即时获取、或已取消）时是无害的 no-op。
  void prioritize(String key) {
    final index = _waiters.indexWhere((waiter) => waiter.key == key);
    if (index <= 0) return;
    final waiter = _waiters.removeAt(index);
    _waiters.insert(0, waiter);
  }
}
