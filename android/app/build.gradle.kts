import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // Kotlin plugin: needed for the `kotlin { compilerOptions { } }` DSL block
    // below. (Plugin modules get this via settings.gradle.kts `beforeProject`.)
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load android/key.properties if present. Absent on fresh clones — release
// builds then FAIL loudly instead of silently falling back to the debug
// signing config (a debug-signed "release" must never be distributed).
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) load(FileInputStream(file))
}

android {
    namespace = "com.open_library.app"
    compileSdk = 37
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.open_library.app"
        minSdk = 29
        // Target Android 17 (API 37) explicitly: Flutter 3.44's
        // flutter.targetSdkVersion is still 36. compileSdk is already 37.
        targetSdk = 37
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Android only, 64-bit only: ship arm64-v8a and nothing else.
        // NOTE: abiFilters must be REPLACED, not appended (+=): the Flutter
        // plugin pre-seeds the set with all three ABIs, so += is a no-op and
        // plugin .so files leak in for armeabi-v7a/x86_64 (v1.4.0 APK was 57 MB).
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
    }

    signingConfigs {
        create("release") {
            val storeFilePath = keystoreProperties["storeFile"] as String?
            if (storeFilePath != null) {
                val candidate = file(storeFilePath)
                if (candidate.exists()) {
                    storeFile = candidate
                    storePassword = keystoreProperties["storePassword"] as String?
                    keyAlias = keystoreProperties["keyAlias"] as String?
                    keyPassword = keystoreProperties["keyPassword"] as String?
                }
            }
        }
    }

    buildTypes {
        release {
            // Release signing requires key.properties + keystore. Refuse to
            // build a release with the debug key: fail here, loudly.
            // Never the debug key. A missing keystore is rejected in the
            // taskGraph check below, so debug builds / tests still configure.
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}

gradle.taskGraph.whenReady {
    val wantsRelease = allTasks.any { t ->
        val n = t.name
        n.contains("Release") &&
            (n.startsWith("assemble") || n.startsWith("bundle") ||
                n.startsWith("package") || n.startsWith("validateSigning"))
    }
    if (wantsRelease && android.signingConfigs.getByName("release").storeFile == null) {
        throw GradleException(
            "Release signing requires android/key.properties with a valid keystore; " +
                "refusing to sign a release build with the debug key."
        )
    }
}

flutter {
    source = "../.."
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// ============================================================================
// Rust / flutter_rust_bridge integration (phase 1 scaffold)
// ============================================================================
// Builds the zlibx_parsers Rust crate for Android arm64-v8a and packages the
// resulting libzlibx_parsers.so into the APK's jniLibs. The .so is built once
// per Gradle build and copied into src/main/jniLibs/arm64-v8a/ before the
// native-lib merge step.

val rustCrateDir = rootProject.file("../rust/zlibx_parsers")
val jniLibsDir = file("src/main/jniLibs/arm64-v8a")

// Path to the Rust crate's .so after a release build for aarch64-linux-android.
val rustSoFile = rustCrateDir.resolve(
    "target/aarch64-linux-android/release/libzlibx_parsers.so"
)

tasks.register<Exec>("cargoBuildRust") {
    group = "rust"
    description = "Build zlibx_parsers Rust crate for Android arm64-v8a"

    // --- Toolchain paths (overridable via env vars) ---
    val cargoHome = System.getenv("CARGO_HOME")
        ?: "${System.getProperty("user.home")}/.cargo"
    val mingwBin = System.getenv("MINGW_BIN") ?: "D:/mingw64/mingw64/bin"
    val androidHome = System.getenv("ANDROID_HOME") ?: "D:/Android/Sdk"
    val ndkHome = System.getenv("ANDROID_NDK_HOME")
        ?: "$androidHome/ndk/28.2.13676358"
    // NDK prebuilt dir name follows the BUILD host, not the target:
    // windows-x86_64 / linux-x86_64 / darwin-x86_64. CI (ubuntu) needs
    // linux-x86_64 — a hardcoded windows dir made cc-rs fall back to
    // its own NDK probe and fail (device/CI-proven).
    val hostTag = when {
        org.gradle.internal.os.OperatingSystem.current().isWindows -> "windows-x86_64"
        org.gradle.internal.os.OperatingSystem.current().isMacOsX -> "darwin-x86_64"
        else -> "linux-x86_64"
    }
    val ndkBin = "$ndkHome/toolchains/llvm/prebuilt/$hostTag/bin"

    // --- Environment for cargo + cc-rs ---
    environment("PATH", "$mingwBin;$cargoHome/bin;${System.getenv("PATH")}")
    environment("ANDROID_HOME", androidHome)
    environment("ANDROID_NDK_HOME", ndkHome)
    // cc-rs and rustc need explicit tool overrides for the Android
    // target (.cargo/config.toml no longer pins a per-OS linker path).
    val isWindows = org.gradle.internal.os.OperatingSystem.current().isWindows
    val clangName = if (isWindows) "aarch64-linux-android29-clang.cmd" else "aarch64-linux-android29-clang"
    environment("CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER", "$ndkBin/$clangName")
    environment("CC_aarch64_linux_android", "$ndkBin/$clangName")
    environment("AR_aarch64_linux_android", "$ndkBin/llvm-ar")
    environment("RANLIB_aarch64_linux_android", "$ndkBin/llvm-ranlib")

    val cargoBin = file("$cargoHome/bin/cargo.exe")
    commandLine(
        if (cargoBin.exists()) cargoBin else "cargo",
        "build", "--release",
        "--target", "aarch64-linux-android",
    ).workingDir(rustCrateDir)

    // Re-run whenever the Rust sources change.
    inputs.dir(rustCrateDir.resolve("src"))
    inputs.file(rustCrateDir.resolve("Cargo.toml"))
    outputs.file(rustSoFile)
}

tasks.register<Copy>("copyRustSo") {
    group = "rust"
    description = "Copy libzlibx_parsers.so into jniLibs for packaging"

    dependsOn("cargoBuildRust")

    from(rustSoFile)
    into(jniLibsDir)
    rename { "libzlibx_parsers.so" }

    // Re-run copy only when the .so is newer.
    inputs.file(rustSoFile)
    outputs.dir(jniLibsDir)
}

// Hook into the native-lib packaging: ensure the .so is built and in place
// before the APK's jniLibs are merged.
tasks.matching { it.name.contains("MergeNativeLibs", ignoreCase = true) }
    .configureEach { dependsOn("copyRustSo") }
// Also cover the Flutter-native-assets / packaging path for debug/profile.
tasks.matching {
    it.name.startsWith("merge") && it.name.contains("JniLib", ignoreCase = true)
}.configureEach { dependsOn("copyRustSo") }

