// Pending-URI download writer.
//
// On Android 10+ the download engines can stream bytes directly into a
// MediaStore entry created with IS_PENDING=1, instead of staging the
// book in the app-specific dir and copying it into Downloads/zlibx
// afterwards (saves one full-file copy and the staging space).
//
// This class owns that entry: it buffers chunks, hands them to the
// platform in 1 MB batches (append mode, so a retry must resume from
// exactly the committed byte count), and persists a small JSON sidecar
// (`<savePath>.pending.json`) so an interrupted download — user retry
// or app kill — resumes the same pending entry.
//
// Throughput (item-5 speed fix): the network stream is never paused
// for a disk write. [add] only queues a full batch and returns; the
// batches are written strictly in order by a background chain, and the
// download loop is only held back when it runs more than
// [_maxBatchesAhead] batches ahead of the disk. The Kotlin side keeps
// ONE append stream open per entry for the whole download. Overall
// speed is therefore min(network, MediaStore write) — the same overlap
// the old `.part` IOSink gave — instead of network + write in series.
//
// The ResumableDownloader `.meta` validator sidecar is untouched: it
// lives next to the same `.part` path and is removed by [discard] /
// [finish] like a completed staged download would.
//
// Resume safety (B1): the sidecar can lag the entry — if the process
// dies after a chunk was committed but before the sidecar was written,
// resuming from the stale sidecar offset would duplicate bytes. So
// [resume] reconciles against the entry's true size (queried from the
// platform) and treats that as authoritative.
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:olib_api_plugin/olib_api_plugin.dart';

import 'media_store.dart';

/// Streams download bytes into a pending MediaStore entry.
///
/// Implements [PendingDownloadWriter] (defined in the vendor plugin)
/// so both download engines — [ResumableDownloader] in this app and
/// `_downloadOnce` inside olib_api_plugin — can write through it
/// without the plugin depending on app code.
class PendingUriWriter implements PendingDownloadWriter {
  PendingUriWriter._({required String uri, required String savePath})
    : _uri = uri,
      _savePath = savePath,
      _statePath = statePathFor(savePath) {
    _live[_statePath] = this;
  }

  /// The newest writer per sidecar path. A retry builds a fresh writer
  /// (see [resume]) while the failed attempt's already-queued batches
  /// may still be landing; [resume] waits for them first, so the size
  /// it reconciles against is final and no late batch can append after
  /// the new writer has picked its resume offset.
  static final Map<String, PendingUriWriter> _live =
      <String, PendingUriWriter>{};

  /// JSON sidecar next to the `.part` path. Holds the pending URI and
  /// the committed byte count; written after every successful batch.
  static String statePathFor(String savePath) => '$savePath.pending.json';

  /// Coalesce threshold: chunks are buffered in memory until this
  /// size crosses, so the platform channel runs once per 1 MB, not once
  /// per network chunk. (The stream stays open in Kotlin, so a batch no
  /// longer pays an open / close — the size only trades channel round
  /// trips against memory.)
  static const int _flushThreshold = 1024 * 1024;

  /// How many queued batches the download loop may run ahead of the
  /// disk before [add] makes it wait: at most ~8 MB in flight plus
  /// the sub-1 MB buffer.
  static const int _maxBatchesAhead = 8;

  String _uri;
  final String _savePath;
  final String _statePath;

  final List<List<int>> _bufferedChunks = <List<int>>[];
  var _buffered = 0;
  var _committed = 0;
  var _closed = false;

  /// Tail of the in-order write chain. Every step catches its own
  /// errors (see [_writeBatch]), so awaiting it never throws.
  Future<void> _tail = Future<void>.value();

  /// Completion futures of the most recent queued batches (sliding
  /// window for [_maxBatchesAhead]).
  final Queue<Future<void>> _batches = Queue<Future<void>>();

  /// Bytes handed to the chain and not yet finished (committed or
  /// failed).
  var _queuedBytes = 0;

  /// First write failure. Sticky: once set, every later batch is
  /// skipped (a gap would corrupt the file) and [add] / [flush] throw.
  StateError? _writeError;

  /// The MediaStore entry currently being filled. Changes when
  /// [reset] recreates the entry after a server-side restart.
  @override
  String get uri => _uri;

  /// Resume offset for the next request: bytes committed to the
  /// pending entry plus bytes queued or still in the buffer.
  @override
  int get bytesWritten => _committed + _queuedBytes + _buffered;

  /// Bytes actually committed to the MediaStore entry (what the
  /// sidecar persists).
  int get committedBytes => _committed;

  /// Display name derived from the `.part` path (`Title - id.ext.part`
  /// → `Title - id.ext`). Needed to recreate the entry in [reset].
  String get _displayName {
    final base = _savePath.split(Platform.pathSeparator).last;
    return base.endsWith('.part') ? base.substring(0, base.length - 5) : base;
  }

  String get _mimeType => MediaStoreFiles.mimeTypeForExtension(
    _displayName.contains('.') ? _displayName.split('.').last : null,
  );

  /// Create a fresh pending entry. Null when MediaStore cannot create
  /// it (pre-Android 10, or any insert failure) — the caller then
  /// falls back to the staged `.part` flow.
  static Future<PendingUriWriter?> create({
    required String displayName,
    required String mimeType,
    required String savePath,
  }) async {
    final uri = await MediaStoreFiles.createPendingDownload(
      displayName: displayName,
      mimeType: mimeType,
    );
    if (uri == null) return null;
    final writer = PendingUriWriter._(uri: uri, savePath: savePath);
    await writer._persistState();
    return writer;
  }

  /// Resume a previously interrupted pending download from its
  /// sidecar. Returns null when there is no (valid) sidecar. The
  /// caller must still verify the URI with MediaStoreFiles.exists —
  /// the entry may have been removed externally.
  ///
  /// Reconciles the sidecar against the entry's true size: the sidecar
  /// is only written after a chunk commit, so a process killed in
  /// between leaves it lagging. The entry's size is authoritative; when
  /// it differs, it wins and the sidecar is updated. When the size
  /// query fails, the sidecar value is kept.
  static Future<PendingUriWriter?> resume({required String savePath}) async {
    final previous = _live[statePathFor(savePath)];
    if (previous != null) await previous._settle();
    final file = File(statePathFor(savePath));
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final uri = decoded['uri'];
      final bytes = decoded['bytesWritten'];
      if (uri is! String || uri.isEmpty || bytes is! int || bytes < 0) {
        return null;
      }
      final writer = PendingUriWriter._(uri: uri, savePath: savePath);
      writer._committed = bytes;
      final actual = await MediaStoreFiles.pendingEntrySize(uri);
      if (actual >= 0 && actual != writer._committed) {
        writer._committed = actual;
        await writer._persistState();
      }
      return writer;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Buffer one network chunk. Once 1 MB accumulates the batch is
  /// queued for writing and this returns immediately — the disk write
  /// happens in the background. Only when the loop is more than
  /// [_maxBatchesAhead] batches ahead of the disk does this wait. A
  /// failed write (storage full, device refusing "wa", entry gone)
  /// surfaces here or in [flush] as a [StateError] — the caller aborts.
  @override
  Future<void> add(List<int> chunk) async {
    if (_closed) {
      throw StateError('pending writer is closed');
    }
    _throwIfFailed();
    // Snapshot the bytes at the API boundary. Callers may reuse a
    // network buffer as soon as add() completes; retaining that
    // mutable list until the next 1 MB batch is assembled can corrupt
    // the bytes eventually written to MediaStore.
    final snapshot = Uint8List.fromList(chunk);
    _bufferedChunks.add(snapshot);
    _buffered += snapshot.length;
    if (_buffered < _flushThreshold) return;
    _enqueueBuffered();
    while (_batches.length > _maxBatchesAhead) {
      await _batches.removeFirst();
    }
    _throwIfFailed();
  }

  /// Commit all buffered bytes to the pending entry (waits for every
  /// queued batch to land) and update the sidecar. Throws when a
  /// platform write failed.
  @override
  Future<void> flush() async {
    if (_buffered > 0) _enqueueBuffered();
    await _tail;
    _batches.clear();
    _throwIfFailed();
  }

  /// Flush and close; no further [add] / [reset] afterwards.
  Future<void> close() async {
    await flush();
    _closed = true;
  }

  /// Move the buffered chunks into one batch and append it to the
  /// write chain. Never awaits the write.
  void _enqueueBuffered() {
    final data = Uint8List(_buffered);
    var offset = 0;
    for (final chunk in _bufferedChunks) {
      data.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    _bufferedChunks.clear();
    _buffered = 0;
    _queuedBytes += data.length;
    final done = _tail.then((_) => _writeBatch(data));
    _tail = done;
    _batches.addLast(done);
  }

  /// One step of the write chain. Never throws: a failure is recorded
  /// in [_writeError] and every later step skips its write.
  Future<void> _writeBatch(Uint8List data) async {
    try {
      if (_writeError == null) {
        if (await MediaStoreFiles.writePendingChunk(_uri, data)) {
          _committed += data.length;
          await _persistState();
        } else {
          _writeError = StateError(
            'MediaStore pending write failed at $_committed bytes',
          );
        }
      }
    } catch (e) {
      _writeError = StateError(
        'MediaStore pending write failed at $_committed bytes: $e',
      );
    } finally {
      _queuedBytes -= data.length;
    }
  }

  void _throwIfFailed() {
    final error = _writeError;
    if (error != null) throw error;
  }

  /// Wait until every queued batch has finished (written or skipped).
  Future<void> _settle() => _tail;

  /// Discard the pending entry and all sidecars (user cancel, HTML
  /// rejection, unrecoverable failure). Also removes the `.meta`
  /// validator like a deleted partial would.
  @override
  Future<void> discard() async {
    // Queued batches must not be written into an entry that is about
    // to be deleted: mark the chain failed so they skip, then wait for
    // the one write that may already be in flight.
    _writeError ??= StateError('pending download discarded');
    await _tail;
    await MediaStoreFiles.abortPendingDownload(_uri);
    if (identical(_live[_statePath], this)) _live.remove(_statePath);
    for (final path in <String>[_statePath, '$_savePath.meta']) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } on FileSystemException {
        // Best-effort cleanup.
      }
    }
  }

  /// Recreate the pending entry empty and point this writer at the
  /// new URI. Required when the server refuses to honour the resume
  /// offset (200 or 416 on a resume request): the old entry cannot be
  /// truncated, only replaced — appending a restarted body would
  /// corrupt the file. False when the new entry cannot be created.
  @override
  Future<bool> reset() async {
    if (_closed) return false;
    // Drop queued batches (skipped via the sticky error), wait for the
    // write in flight, then start clean on the new entry.
    _writeError ??= StateError('pending entry is being recreated');
    await _tail;
    _batches.clear();
    _writeError = null;
    await MediaStoreFiles.abortPendingDownload(_uri);
    _bufferedChunks.clear();
    _buffered = 0;
    _committed = 0;
    final fresh = await MediaStoreFiles.createPendingDownload(
      displayName: _displayName,
      mimeType: _mimeType,
    );
    if (fresh == null) return false;
    _uri = fresh;
    await _persistState();
    return true;
  }

  /// Flush the remaining buffer and publish the entry (clear
  /// IS_PENDING). Removes the pending sidecar and the `.meta`
  /// validator on success. False when publishing fails — the caller
  /// treats the download as failed and must not record the URI.
  Future<bool> finish() async {
    await close();
    final published = await MediaStoreFiles.finishPendingDownload(_uri);
    if (!published) return false;
    if (identical(_live[_statePath], this)) _live.remove(_statePath);
    for (final path in <String>[_statePath, '$_savePath.meta']) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } on FileSystemException {
        // Best-effort cleanup.
      }
    }
    return true;
  }

  Future<void> _persistState() async {
    final stateFile = File(_statePath);
    final tempFile = File('$_statePath.tmp');
    try {
      // Write and flush a complete replacement before publishing it.
      // This avoids leaving a truncated JSON sidecar if the process is
      // interrupted during serialization or disk I/O.
      await tempFile.writeAsString(
        jsonEncode(<String, Object>{'uri': _uri, 'bytesWritten': _committed}),
        flush: true,
      );
      try {
        await tempFile.rename(_statePath);
      } on FileSystemException {
        // Some platforms do not replace an existing destination on
        // rename. Fall back to deleting the destination first; if the
        // replacement rename also fails, the outer handler cleans up
        // the temp file (losing the sidecar only costs a fresh
        // download on retry).
        if (await stateFile.exists()) {
          await stateFile.delete();
        }
        await tempFile.rename(_statePath);
      }
    } on FileSystemException {
      // Losing the sidecar only costs a fresh download on retry.
      // Best-effort cleanup prevents stale temporary files accumulating.
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } on FileSystemException {
        // Best effort.
      }
    }
  }
}
