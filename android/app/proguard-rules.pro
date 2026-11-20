# zlibx release keep rules (review A3, 2026-11-20).
#
# R8 runs with isMinifyEnabled / isShrinkResources. AGP auto-keeps the
# AndroidManifest components and every Flutter plugin ships consumer
# rules (flutter_inappwebview, local_auth, flutter_secure_storage), so
# this file only pins the contract explicitly: our own Kotlin classes
# that manifest / MethodChannel wiring refers to, kept visible for
# future manifest or package refactors. The CI release job smoke-checks
# both classes survive in the shipped dex (apkanalyzer).
-keep class com.open_library.app.MainActivity { *; }
-keep class com.open_library.app.DownloadForegroundService { *; }

# flutter_rust_bridge talks over dart:ffi — no JNI reflection on the
# Rust side, so no keeps are needed for the parser crate.
