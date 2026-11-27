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
    namespace = "com.minglaiyo.zlibx"
    compileSdk = 37
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    androidResources {
        localeFilters += listOf(
            "en",
            "zh",
            "b+zh+Hant",
            "ja",
            "ko",
            "zh-rTW",
            "zh-rHK",
            "b+zh+MO",
        )
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    defaultConfig {
        applicationId = "com.minglaiyo.zlibx"
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
            // Explicit keep rules (review A3, 2026-11-20): document
            // the release-shrinking contract. AGP already keeps the
            // manifest components and every Flutter plugin ships
            // consumer rules, so the file is intentionally short.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
// Rust / flutter_rust_bridge integration (primary parse path)
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

    // --- Toolchain paths ---
    // 审查（可移植性）：旧版把维护者本机盘符当默认值（D:/mingw64、
    // D:/Android/Sdk），新机器克隆后必然静默失效。解析顺序改为
    // env → local.properties(不入库) → AGP 解析值，Windows 缺 MinGW
    // 直接显式报错，不再猜路径。
    val os = org.gradle.internal.os.OperatingSystem.current()
    val pathSep = if (os.isWindows) ";" else ":"
    val localProps = Properties().apply {
        val f = rootProject.file("local.properties")
        if (f.exists()) load(FileInputStream(f))
    }
    val cargoHome: String = System.getenv("CARGO_HOME")
        ?: "${System.getProperty("user.home")}/.cargo"
    val sdkDirProp: String? = localProps.getProperty("sdk.dir")?.replace("\\", "/")
    val androidHome: String = System.getenv("ANDROID_HOME")
        ?: sdkDirProp
        ?: android.sdkDirectory.path
    val ndkHomeEnv: String? = System.getenv("ANDROID_NDK_HOME")
    val ndkHome: String = ndkHomeEnv
        ?: "$androidHome/ndk/${android.ndkVersion}"
    // Windows 上 cargo 的 host 构建脚本（proc-macro 编译到
    // x86_64-pc-windows-gnu）需要 MinGW gcc；其他平台没有这个角色。
    // 显式 null 标注绕开 Gradle kts 对平台类型 elvis 的误报。
    val mingwBin: String? = if (os.isWindows) {
        val envBin: String? = System.getenv("MINGW_BIN")
        val propBin: String? = localProps.getProperty("mingw.bin")
        envBin ?: propBin ?: throw GradleException(
            "Building the Rust parsers on Windows needs a MinGW-w64 " +
            "bin dir on PATH: set MINGW_BIN env or add " +
            "`mingw.bin=C:/path/to/mingw64/bin` to android/local.properties.",
        )
    } else {
        null
    }
    // NDK prebuilt dir name follows the BUILD host, not the target:
    // windows-x86_64 / linux-x86_64 / darwin-x86_64. CI (ubuntu) needs
    // linux-x86_64 — a hardcoded windows dir made cc-rs fall back to
    // its own NDK probe and fail (device/CI-proven).
    val hostTag = when {
        os.isWindows -> "windows-x86_64"
        os.isMacOsX -> "darwin-x86_64"
        else -> "linux-x86_64"
    }
    val ndkBin = "$ndkHome/toolchains/llvm/prebuilt/$hostTag/bin"

    // --- Environment for cargo + cc-rs ---
    environment(
        "PATH",
        listOfNotNull(mingwBin, "$cargoHome/bin", System.getenv("PATH"))
            .joinToString(pathSep),
    )
    environment("ANDROID_HOME", androidHome)
    environment("ANDROID_NDK_HOME", ndkHome)
    // cc-rs and rustc need explicit tool overrides for the Android
    // target (.cargo/config.toml no longer pins a per-OS linker path).
    val isWindows = os.isWindows
    val clangName = if (isWindows) "aarch64-linux-android29-clang.cmd" else "aarch64-linux-android29-clang"
    environment("CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER", "$ndkBin/$clangName")
    environment("CC_aarch64_linux_android", "$ndkBin/$clangName")
    environment("AR_aarch64_linux_android", "$ndkBin/llvm-ar")
    environment("RANLIB_aarch64_linux_android", "$ndkBin/llvm-ranlib")

    // cargo 可执行文件按平台取：Windows 上是 cargo.exe，其他平台
    // 是 cargo。旧版按文件存在性判断，在 PATH 里有 cargo 但
    // $CARGO_HOME/bin 下没有时会静默用错（P2-6）。
    val cargoBin = if (os.isWindows) file("$cargoHome/bin/cargo.exe") else "cargo"
    commandLine(
        cargoBin,
        "build", "--release", "--locked",
        "--target", "aarch64-linux-android",
    ).workingDir(rustCrateDir)

    // Re-run whenever the Rust sources change — and whenever anything
    // else the build reads changes (P2-6): a dependency upgrade only
    // touches Cargo.lock, the linker choice lives in .cargo/config.toml,
    // and the NDK version picks the clang that compiles the crate. Any
    // of those changing without a rebuild used to leave a stale .so.
    inputs.dir(rustCrateDir.resolve("src"))
    inputs.file(rustCrateDir.resolve("Cargo.toml"))
    inputs.file(rustCrateDir.resolve("Cargo.lock"))
    inputs.file(rustCrateDir.resolve(".cargo/config.toml"))
    inputs.property("ndkVersion", android.ndkVersion)
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
// P2-6：这两处是按任务名匹配的挂接，对 AGP 升级较敏感——AGP 改名后
// 挂接会静默失效、.so 不再进包。升级 AGP 后要复核：CI 里 apkanalyzer
// 那步会检查 libzlibx_parsers.so 在包内（见工作流
// "Smoke-check release dex for native-layer classes"）。
tasks.matching { it.name.contains("MergeNativeLibs", ignoreCase = true) }
    .configureEach { dependsOn("copyRustSo") }
// Also cover the Flutter-native-assets / packaging path for debug/profile.
tasks.matching {
    it.name.startsWith("merge") && it.name.contains("JniLib", ignoreCase = true)
}.configureEach { dependsOn("copyRustSo") }

