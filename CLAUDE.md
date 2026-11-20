# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

zlibx is a slim, Android-only (arm64-v8a) Flutter fork of shiyi-0x7f/olib-mobile: a Z-Library reader with Anna's Archive and LibGen sources added. No AI features, no ads, no WeRead. License is AGPL-3.0 (the original MIT text is preserved in LICENSE). The UI and commit messages are primarily in Chinese.

## Build & Run Commands

```bash
flutter pub get                  # Install dependencies
flutter run                      # Run debug build
flutter build apk --release --target-platform android-arm64  # Build release APK (arm64-v8a only)
dart run flutter_launcher_icons  # Regenerate app icons (source: tool/icons/olib-app-logo.png)
flutter analyze                  # Run linter
flutter test                     # Run the test suite under test/
```

Models are hand-written: `Book`/`User` and all other models use no freezed, no json_serializable, no build_runner. Do not add generated-model tooling. Localization is the one exception — gen-l10n generates `lib/l10n/generated/` from the ARB files (see Internationalization).

## Architecture

**Layered organization** in `lib/`:

- **`services/`** — API clients and storage. The Z-Library client is `ZLibraryApi` in `vendor/olib_api_plugin/lib/src/zlibrary_api.dart` (Dio with a hand-managed Cookie header; there is no cookie jar). External sources live in `lib/services/annas_archieve.dart` (Anna's Archive — yes, the filename typo is real, do not rename it casually) and `lib/services/libgen_service.dart` (LibGen). Mirror lists come from open-slum.org via `lib/services/slum_catalogue.dart`, `lib/core/slum.dart`, `lib/services/instance_manager.dart`. Cloudflare/DDoS-Guard-style challenge pages are solved in a WebView by `lib/services/webview_challenge_solver.dart` with `lib/services/challenge_html_cache.dart`. One shared Dio factory lives in `lib/services/http_client.dart` (`createDio`); do not create ad-hoc `Dio()` instances.
- **`providers/`** — Riverpod state management. `NotifierProvider` (Riverpod 2 `Notifier`) for mutable state (auth, downloads, domain selection, settings). `FutureProvider` / `FutureProvider.family` for async data (search, book details, popular lists).
- **`screens/`** — UI pages, each a `ConsumerWidget` or `ConsumerStatefulWidget`.
- **`models/`** — Hand-written models (`Book`, `User` in the vendor plugin; `display_book.dart` etc. in `lib/models/`).
- **`widgets/`** — Shared reusable UI components.
- **`vendor/olib_api_plugin/`** — The in-repo Z-Library client plugin (Dio API + models). Committed to this repo; CI verifies it is present. Do not change its interface behavior without a reason.

**State management**: Riverpod (classic hand-written providers, not `@riverpod` annotation style).

**Routing**: Named routes via `MaterialApp.routes`. Route constants in `lib/routes/app_routes.dart`.

**Local storage**: Hive boxes for non-secret state (settings, caches, download history). Credentials (account session, tokens) live in `flutter_secure_storage` (Android Keystore), never in Hive — see `lib/services/secure_storage.dart` and `lib/services/auth_storage.dart`.

**Internationalization**: gen-l10n ARB. Message files are `lib/l10n/app_<locale>.arb` (template `app_en.arb`, 397 keys). The language picker offers 5 languages — en, zh, zh_Hant, ja, ko — and the tree also carries `app_zh_TW.arb` / `app_zh_HK.arb` / `app_zh_MO.arb` for regional Traditional Chinese locales. `l10n.yaml` sets `synthetic-package: false` + `output-dir: lib/l10n/generated`; `generate: true` in `pubspec.yaml` regenerates that directory on `flutter pub get`, and `.gitignore` keeps it out of the repo. Usage: `AppLocalizations.of(context)!` (the getter returns a nullable). Pass the complete `AppLocalizations.localizationsDelegates` list — in `MaterialApp` and in widget tests — otherwise the debug-only localization check fails for non-English locales.

## Tests

`test/` is organised as `test/parsers/` (HTML/JSON parsers), `test/services/` (providers, caches, storage, downloader, trust), `test/providers/` (Riverpod notifier tests), `test/widgets/` (widget tests), `test/l10n/` (localization string/resolution tests) and `test/routes/` (route table and argument guards). Nothing under `test/` is ignored — a new test directory is committed like any source (the old `test/*` + per-directory un-ignore whitelist, which silently dropped new directories, was removed in M7).

## Rust parsing layer (flutter_rust_bridge)

The HTML parsing layer lives in `rust/zlibx_parsers/` (Rust) and is bridged to Dart with flutter_rust_bridge. Every parser ported there has a **differential test**: the Rust side re-runs the SAME inline HTML fixtures as its Dart test (`test/parsers/*_test.dart`) with field-by-field assertions — port a parser only alongside its twin test.

- **Hooks, not call-site rewrites**: the Dart parser stays as the fallback. The vendor plugin exposes `xxxParseOverride` hooks (fulltext / article / booklist×3 / category / book_detail / download_stats / annas ×2 / libgen ×2 / openlibrary); `lib/core/rust_*.dart` modules inject Rust-backed implementations lazily and un-register themselves on bridge failure, so a missing `.so` silently falls back to Dart. Route ALL call sites through the hook (`parseXxxH` wrappers where provided) — both the Dio path (vendor) and the WebView-solver path (app repositories) must be hooked, or one path silently keeps the Dart parse.
- **One FRB init for everything**: `lib/core/rust_init.dart::ensureRustBridge()` is the ONLY place that calls `ZlibxParsers.init()`. FRB's `initImpl` throws on a second call, so per-module init guards made every parser after the first silently fall back to Dart (device-proven). New hook modules must use the shared guard, never call `ZlibxParsers.init()` directly.
- **FRB upgrade policy** (audit 2026-11-19): the bridge sits on an exact-pinned `2.14.0-beta.2` on BOTH sides (pubspec + Cargo.toml). To bump it: first `cargo test --release` (97 differential tests) plus `flutter test`, then run `bash tool/frb_codegen.sh`, re-apply the known codegen workaround below, and diff the generated files — a silent generator-behaviour change in a beta is exactly what the differential tests exist to catch. Switch off the beta as soon as FRB 2.x stable ships.
- **FRB codegen**: `bash tool/frb_codegen.sh` after changing `#[frb]` functions. It patches a known FRB codegen bug (`RustAutoOpaqueInner<str>` — `str` is not `Sized`) after generation. The generated files (`lib/frb_generated*`, `lib/lib.dart`, `lib/models.dart`, `rust/.../frb_generated.rs`) ARE committed — CI has no Rust toolchain and `flutter analyze` needs them at checkout. Commit them together with the `#[frb]` change that regenerated them; do not hand-edit.
- **Crate conventions**: internal parser functions are `pub(crate)` (FRB with `rust_input: crate` scans every `pub` fn and generates bindings for it); `Option<String>` parameters don't work (FRB wraps them in RustOpaque) — entry signatures use `String` with an empty-string convention for "absent". Regexes are cached in `OnceLock` (re-compiling per call cost 13× on the hot path).
- **The Android linker is env-driven**: `rust/zlibx_parsers/.cargo/config.toml` deliberately does NOT pin a per-OS linker path. Gradle's `cargoBuildRust`, `tool/cargo_build_android.sh` and the release CI job all set `CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER` / `CC_` / `AR_` / `RANLIB_aarch64_linux_android` from the NDK. If the release CI fails inside cargo, check those env vars first.
- **Rust tests**: `cargo test --release` in `rust/zlibx_parsers/` (needs MinGW-w64 on Windows for the host C toolchain; the GNU toolchain's own gcc is a linker-only stub).

## Key Patterns

- `ZLibraryApi` has no async init step: `zlibraryApiProvider` constructs it on the persisted domain (`resolveInitialDomain()`), and every request is built against that host.
- Domain/mirror switching goes through `DomainNotifier` → `ZLibraryApi.setDomain`, which changes the host for subsequent requests; device-side speed testing is in `lib/services/mirror_speed_test.dart`.
- Multi-account support: `AuthStorage` persists multiple credential sets in secure storage.
- Downloads are single-stream with resume (`Range` + `If-Range` + append to a stable `<final>.part` file, validator in `<final>.part.meta`). Segmented parallel downloading is deliberately NOT implemented. The external-source path (Anna's Archive / LibGen direct links) goes through `lib/services/resumable_downloader.dart` (rejects HTML answers, flags truncated streams); the Z-Library path has its own equivalent checks in `vendor/olib_api_plugin` (`_downloadOnce`) — keep the two in step. The preset download carries no custom headers (S5): dio follows redirects itself, and custom headers would travel to the redirect target.
- Swallowed exceptions must go through `logIgnored(tag, error)` (`lib/utils/diagnostics.dart`), never a bare `debugPrint`: it keeps a bounded in-memory trail (tag + exception type only, no message) that works in release builds.
- Credentials only go to confirmed hosts: `lib/services/mirror_trust.dart` + `confirmMirrorTrust()` ask once per community mirror before login / line switch, and `DomainNotifier.setDomain` refuses to re-send the session to an unconfirmed host.
- Update-dialog links are restricted to `UpdateManifest.allowedLinkHosts`; add a host there before using a new netdisk in a release.
- Widgets that show ONE download should watch `downloadTaskProvider(id)`, not the whole `downloadProvider` list.
- Anna's Archive fast download needs the user's own donation key, entered by the user in Settings (never ask the user to send it to you).

## Release signing

The release APK is signed with `android/app/olib-release-key.jks` (alias `olib-release`, PKCS12). The keystore and `android/key.properties` are **gitignored — never commit them**; losing the key means the app can never be updated for existing installs.

- **Local builds**: copy `android/key.properties.example` to `android/key.properties` and point `storeFile` at the keystore (missing file/keystore makes release builds fail loudly instead of silently signing with the debug key).
- **CI**: the release job restores the keystore from four repo Secrets — `KEYSTORE_BASE64` (base64 of the .jks), `KEYSTORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS` — then writes `android/key.properties` itself. Update them with `gh secret set NAME --repo minglaiyo/zlibx`.
- Generate a replacement: `keytool -genkeypair -keystore olib-release-key.jks -alias olib-release -keyalg RSA -keysize 4096 -validity 10950` (10 950 days ≈ Google Play's minimum horizon).

## Dependency Tracking (review B3, 2026-11-20)

- flutter_rust_bridge pinned at 2.14.0-beta.2 on both ends; evaluate the
  stable switch when it lands. The generated code carries a manual
  `RustAutoOpaqueInner<str>` patch — the main regression risk on upgrade.
- Hive 2.x is unmaintained but stabilized by the LazyBox / library-box
  work (A1/A2, 2026-11-20); revisit a replacement (drift/sqflite) only
  after the post-migration data-layer boundary proves stable for a few
  releases.
- dynamic_color capped <1.9.0 for the local old Flutter; lift the cap
  once the local toolchain matches CI (3.44).
- B1: the Dart parser fallbacks' trigger rate is measurable via the
  logIgnored `frb_*` tags; observe one or two releases before retiring
  any Dart parser.

## Repo Notes

- Android build uses `android/build.gradle.kts`. China-based Maven mirrors (Aliyun) are added only when the `useCnMirror` Gradle property is set; CI does not use them.
- Requires Dart SDK ^3.10.0; CI pins Flutter 3.44.0. Android `compileSdk = 37`, `minSdk = 29` (Android 10), arm64-v8a only (`abiFilters`).
- CI workflow: `.github/workflows/oliblite-build-android-arm64.yml` ("Build Android APK") — runs `flutter analyze` and `flutter test` before building the release APK; publishes a GitHub Release only on tag pushes.
- Release signing uses a keystore restored from repo secrets in CI; the workflow refuses to build if the signing material is missing.
