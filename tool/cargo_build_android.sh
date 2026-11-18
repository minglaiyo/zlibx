#!/usr/bin/env bash
# Build zlibx_parsers Rust crate for Android arm64-v8a.
#
# Sets up the required environment (MinGW host toolchain, NDK clang for the
# Android target) and runs `cargo build --release --target aarch64-linux-android`.
# Called by the Gradle `cargoBuildRust` task in android/app/build.gradle.kts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_DIR="$ROOT/rust/zlibx_parsers"

# --- Resolve toolchain paths ---
# MinGW (host C toolchain for build scripts like dart-sys)
MINGW_BIN="${MINGW_BIN:-D:/mingw64/mingw64/bin}"
# Cargo / rustup
CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
# NDK (Android target linker + ar)
NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_HOME:-D:/Android/Sdk}/ndk/28.2.13676358}"
# NDK prebuilt dir follows the BUILD host (windows/linux/darwin).
case "$(uname -s)" in
  MINGW*|CYGWIN*) HOST_TAG="windows-x86_64" ;;
  Darwin*)        HOST_TAG="darwin-x86_64" ;;
  *)              HOST_TAG="linux-x86_64" ;;
esac
NDK_BIN="$NDK_HOME/toolchains/llvm/prebuilt/$HOST_TAG/bin"

# --- Environment ---
export PATH="$MINGW_BIN:$CARGO_HOME/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-D:/Android/Sdk}"
export ANDROID_NDK_HOME="$NDK_HOME"

# cc-rs and rustc need explicit tool overrides for the Android target
# (.cargo/config.toml no longer pins a per-OS linker path).
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == CYGWIN* ]]; then
  CLANG_NAME="aarch64-linux-android29-clang.cmd"
else
  CLANG_NAME="aarch64-linux-android29-clang"
fi
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/$CLANG_NAME"
export CC_aarch64_linux_android="$NDK_BIN/$CLANG_NAME"
export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"
export RANLIB_aarch64_linux_android="$NDK_BIN/llvm-ranlib"

cd "$CRATE_DIR"
cargo build --release --target aarch64-linux-android "$@"
