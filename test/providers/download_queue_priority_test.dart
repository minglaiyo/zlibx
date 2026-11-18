import 'package:flutter_test/flutter_test.dart';
import 'package:olib_api_plugin/olib_api_plugin.dart';
import 'package:zlibx/providers/download_provider.dart';
import 'package:zlibx/providers/download_slot_pool.dart';

/// E2 队列置顶（slot 池按键插队）与 E1 任务旗标。
void main() {
  group('DownloadSlotPool.prioritize', () {
    test('等待队列里的任务置顶后先拿槽位', () async {
      final pool = DownloadSlotPool(maxConcurrent: 2);

      // 占满两个槽位。
      await pool.acquire(key: 'a');
      await pool.acquire(key: 'b');
      expect(pool.activeCount, 2);
      expect(pool.waitingCount, 0);

      // 两个任务排队：c 先排，d 后排。
      final cAcquired = pool.acquire(key: 'c');
      final dAcquired = pool.acquire(key: 'd');
      await Future<void>.delayed(Duration.zero);
      expect(pool.waitingCount, 2);

      // 置顶 d（后排的先走）。
      pool.prioritize('d');

      pool.release(); // 一个槽位空出 → d 先拿到。
      await Future<void>.delayed(Duration.zero);
      expect(pool.waitingCount, 1);
      expect(dAcquired, completion(isNull));
      pool.release(); // 最后一个槽位 → c。
      await Future<void>.delayed(Duration.zero);
      expect(cAcquired, completion(isNull));
      expect(pool.waitingCount, 0);
    });

    test('置顶不在队列里的 key 是无害 no-op', () async {
      final pool = DownloadSlotPool(maxConcurrent: 1);
      await pool.acquire(key: 'a');
      pool.prioritize('a'); // 已持有槽位（不在等待队列）→ no-op。
      pool.prioritize('ghost'); // 从未排队 → no-op。
      pool.release();
      await Future<void>.delayed(Duration.zero);
      expect(pool.waitingCount, 0);
    });
  });

  group('DownloadTask flags', () {
    const book = Book(id: 7, title: 'T', hash: 'h');

    test('wifiOnlyBlocked / pinned 缺省 false，copyWith 可覆写', () {
      const task = DownloadTask(id: '7', book: book);
      expect(task.wifiOnlyBlocked, isFalse);
      expect(task.pinned, isFalse);

      final blocked = task.copyWith(
        status: DownloadStatus.error,
        wifiOnlyBlocked: true,
      );
      expect(blocked.wifiOnlyBlocked, isTrue);
      expect(blocked.pinned, isFalse);

      final pinned = blocked.copyWith(pinned: true);
      expect(pinned.pinned, isTrue);
      // 错误态旗标不丢。
      expect(pinned.wifiOnlyBlocked, isTrue);
    });

    test('wifi-only 错误态保留 canRetry（到 Wi-Fi 后可重试）', () {
      final task = DownloadTask(
        id: '7',
        book: book,
        status: DownloadStatus.error,
        wifiOnlyBlocked: true,
      );
      expect(task.canRetry, isTrue);
    });
  });
}
