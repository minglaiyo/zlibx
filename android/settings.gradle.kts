pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // China mirrors for faster downloads
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        // Fallback to original
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.12.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")

// Apply the Kotlin plugin to Flutter plugin modules (e.g. dynamic_color).
// Their build scripts use the `kotlin { compilerOptions { } }` DSL, which
// requires the plugin. The Flutter plugin loader applies the Android library
// plugin during settings evaluation, so by `beforeProject` time it is already
// present for those modules. The `:app` module applies Kotlin via its own
// `plugins {}` block.
gradle.beforeProject {
    if (plugins.hasPlugin("com.android.library")) {
        apply(plugin = "org.jetbrains.kotlin.android")
    }
}
