// Download-side public types of [ZLibraryApi]: the byte sink the
// app streams a pending-MediaStore download into, and the two
// never-resumable download failures. Split out of
// `zlibrary_api.dart` (review-2 P1-4) as a part in the same
// library — no behaviour change, the types are still exported
// through `olib_api_plugin.dart` exactly as before.
part of 'zlibrary_api.dart';

/// App-facing byte sink for the pending-MediaStore download flow
/// (Android 10+): the app streams bytes straight into an IS_PENDING
/// entry instead of staging a .part file. Implemented by the app's
/// PendingUriWriter; the plugin only ever calls these members, so it
/// has no dependency on app code. All engines keep their current
/// behaviour when no writer is passed.
abstract class PendingDownloadWriter {
  /// The MediaStore entry being filled (changes after [reset]).
  String get uri;

  /// Resume offset: bytes already committed (plus any buffered bytes).
  int get bytesWritten;

  /// Buffer one network chunk; may flush internally.
  Future<void> add(List<int> chunk);

  /// Commit all buffered bytes. Throws when the platform write fails.
  Future<void> flush();

  /// Delete the pending entry and all sidecars (cancel / bad content).
  Future<void> discard();

  /// Recreate the pending entry empty (server restarted the body).
  /// False when the new entry cannot be created.
  Future<bool> reset();
}

/// The server answered a download request with an HTML page (a
/// challenge / error page) instead of the file. Never resumable: the
/// destination (partial file or pending entry) is useless and must be
/// discarded, never resumed.
class DownloadHtmlException implements Exception {
  final String message;
  const DownloadHtmlException(this.message);
  @override
  String toString() => message;
}

/// The downloaded bytes do not carry the magic of the format the file
/// claims to be (plan item 8): a PDF served for an EPUB, a resumed
/// partial whose prefix is not the book, or a finished file whose head
/// is not its format's signature. Never resumable and never
/// auto-retried: the destination is discarded and the user retries
/// from zero.
class DownloadMagicException implements Exception {
  final String message;
  const DownloadMagicException(this.message);
  @override
  String toString() => message;
}
