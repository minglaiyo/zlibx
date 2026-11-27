/// Serialized whole-blob JSON writes, split out of
/// `storage_service.dart` (P1-4). Moved verbatim; no behavior change.
///
/// The download history, downloaded-book metadata and book-detail
/// extras are each one JSON blob in the settings box. A Hive `put`
/// is async, so two concurrent read-modify-write calls for the same
/// key would both read the same stale blob — the second write then
/// silently drops the first one's entry. Chaining each write onto
/// the previous write for the same key makes the read-modify-write
/// atomic per key: a chained write only reads after the previous
/// write's `put` completed. Different keys run independently, and
/// pure reads are NOT serialized (they may see a slightly stale
/// snapshot — acceptable for these caches). The map is static on
/// purpose: the Hive box is global, and StorageService is also
/// constructed directly (main.dart, tests) outside the Riverpod
/// singleton, so an instance field would not serialize writes
/// across instances. It holds at most one entry per blob key (a
/// fixed small set), so no cleanup is needed.
class StorageWriteQueue {
  static final Map<String, Future<void>> _writeChains = {};

  /// Run [work] after the previous write for [key] finished, and
  /// return [work]'s own future to the caller. The stored chain
  /// future never completes with an error — a failed write is
  /// swallowed in the chain — so one failure does not block later
  /// writers for the same key; the caller still sees its own
  /// result/error through the returned future.
  static Future<T> runSerialized<T>(
    String key,
    Future<T> Function() work,
  ) {
    final previous = _writeChains[key];
    final run = (previous ?? Future<void>.value()).then((_) => work());
    _writeChains[key] = run.then<void>((_) {}).catchError((_, __) {});
    return run;
  }
}
