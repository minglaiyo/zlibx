import '../frb_generated.dart' show ZlibxParsers;

/// One-shot FRB engine init, shared by EVERY rust_* hook module.
///
/// FRB's `initImpl` throws on a second call ("Should not initialize
/// flutter_rust_bridge twice") — each hook module having its own guard
/// meant the first hook to fire initialized the engine and every later
/// hook silently fell back to Dart (device-proven 2026-11-17: libgen
/// initialized, annas — firing 20 s later — got the "twice" error and
/// downgraded). All hooks await this single guard instead.
Future<void>? _initFuture;

Future<void> ensureRustBridge() async {
  _initFuture ??= ZlibxParsers.init();
  await _initFuture;
}

/// Drop the shared guard after a failure so a later call re-arms (the
/// hooks that caught the failure have already un-registered themselves
/// and fallen back to Dart).
void resetRustBridge() {
  _initFuture = null;
}
