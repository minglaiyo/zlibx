#!/usr/bin/env bash
# flutter_rust_bridge codegen for zlibx_parsers.
#
# Generates the Dart↔Rust bindings from the #[frb]-annotated functions in
# rust/zlibx_parsers/src/lib.rs:
#   - lib/frb_generated.dart                         (Dart-side bindings)
#   - rust/zlibx_parsers/src/frb_generated.rs       (Rust-side, include! in lib.rs)
#
# Run after any change to the #[frb]-annotated Rust functions. The generated
# files are gitignored (see .gitignore).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Ensure cargo is on PATH (rustup installs to ~/.cargo/bin).
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"

CRATE_NAME="zlibx_parsers"
RUST_ROOT="rust/$CRATE_NAME"
RUST_OUTPUT="$RUST_ROOT/src/frb_generated.rs"
DART_OUTPUT="lib"
DART_ENTRYPOINT="ZlibxParsers"

echo ">> flutter_rust_bridge_codegen generate"
flutter_rust_bridge_codegen generate \
    --rust-input "crate" \
    --rust-root "$RUST_ROOT" \
    --rust-output "$RUST_OUTPUT" \
    --dart-output "$DART_OUTPUT" \
    --dart-entrypoint-class-name "$DART_ENTRYPOINT" \
    --type-64bit-int

echo ">> generated:"
echo "   $DART_OUTPUT/frb_generated.dart"
echo "   $RUST_OUTPUT"

# FRB v2.14.0-beta.2 codegen generates `RustAutoOpaqueInner<str>` for
# `Option<String>` fields, but `str` is not `Sized`, so the crate fails to
# compile. Patch the generated file: `str` → `String` (which is `Sized`
# and the correct inner type for `Option<String>`). This is a known FRB
# codegen bug; re-applied on every codegen run.
if grep -q "RustAutoOpaqueInner<str>" "$RUST_OUTPUT" 2>/dev/null; then
    echo ">> patching FRB codegen bug: RustAutoOpaqueInner<str> -> <String>"
    sed -i 's/RustAutoOpaqueInner<str>/RustAutoOpaqueInner<String>/g' "$RUST_OUTPUT"
fi
