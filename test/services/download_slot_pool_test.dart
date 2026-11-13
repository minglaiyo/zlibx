import 'package:flutter_test/flutter_test.dart';
import 'package:zlibx/providers/download_slot_pool.dart';

void main() {
  group('DownloadSlotPool', () {
    test('acquires up to maxConcurrent immediately', () async {
      final pool = DownloadSlotPool(maxConcurrent: 3);
      await pool.acquire();
      await pool.acquire();
      await pool.acquire();
      expect(pool.activeCount, 3);
      expect(pool.waitingCount, 0);
    });

    test('the (maxConcurrent + 1)-th acquire waits (FIFO)', () async {
      final pool = DownloadSlotPool(maxConcurrent: 2);
      await pool.acquire();
      await pool.acquire();
      var fourthStarted = false;
      final waiting = pool.acquire().then((_) => fourthStarted = true);
      // Let the microtask queue drain: the waiter must NOT complete
      // while both slots are held.
      await Future<void>.delayed(Duration.zero);
      expect(fourthStarted, isFalse);
      expect(pool.activeCount, 2);
      expect(pool.waitingCount, 1);

      pool.release();
      await waiting;
      expect(fourthStarted, isTrue);
      expect(pool.activeCount, 2);
      expect(pool.waitingCount, 0);
    });

    test('release wakes waiters in FIFO order', () async {
      final pool = DownloadSlotPool(maxConcurrent: 1);
      await pool.acquire();
      final order = <int>[];
      final w1 = pool.acquire().then((_) => order.add(1));
      final w2 = pool.acquire().then((_) => order.add(2));
      final w3 = pool.acquire().then((_) => order.add(3));
      await Future<void>.delayed(Duration.zero);
      expect(pool.waitingCount, 3);

      pool.release();
      await w1;
      expect(order, [1]);
      pool.release();
      await w2;
      expect(order, [1, 2]);
      pool.release();
      await w3;
      expect(order, [1, 2, 3]);
      expect(pool.activeCount, 1);
    });

    test('a double release cannot drive the count negative', () {
      final pool = DownloadSlotPool(maxConcurrent: 2);
      pool.release();
      pool.release();
      expect(pool.activeCount, 0);
      expect(pool.waitingCount, 0);
    });

    test('release with no waiters just frees the slot', () async {
      final pool = DownloadSlotPool(maxConcurrent: 1);
      await pool.acquire();
      expect(pool.activeCount, 1);
      pool.release();
      expect(pool.activeCount, 0);
      // The slot is usable again immediately.
      await pool.acquire();
      expect(pool.activeCount, 1);
    });
  });
}
