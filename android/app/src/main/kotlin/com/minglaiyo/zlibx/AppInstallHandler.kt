package com.minglaiyo.zlibx

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

/// In-app update install (`zlibx/app_install` channel, plan 12–16):
/// verify the downloaded APK (streaming SHA-256 + signing
/// certificate vs the running app) and fire the system installer.
/// Verification reads the file on the IO pool; the install intent
/// fires on the platform thread.
///
/// P1-2: [verifyApk] itself never throws — any failure returns a
/// map with `error` set, so Dart never has to guess from a null.
/// The runner only adds a safety net for unexpected throws
/// ("verify_failed"); Dart maps that PlatformException to an
/// error-carrying ApkVerification, as it already does.
class AppInstallHandler(
    private val context: Context,
    private val runner: ChannelRunner,
) {

    /// Dispatches the app_install methods this handler owns.
    /// Returns true when [call] was handled; false otherwise.
    fun handleMethod(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "verifyApk" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.success(
                        mapOf<String, Any?>(
                            "sha256" to null,
                            "sha256Checked" to false,
                            "sha256Matches" to false,
                            "signatureMatches" to false,
                            "apkFingerprint" to null,
                            "currentFingerprint" to null,
                            "error" to "missing path",
                        ),
                    )
                    return true
                }
                runner.runAsync(result, runner.ioExecutor, "verify_failed") {
                    verifyApk(path, call.argument<String>("expectedSha256"))
                }
            }
            "installApk" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.success(false)
                    return true
                }
                result.success(installApk(path))
            }
            "canInstallPackages" -> {
                result.success(context.packageManager.canRequestPackageInstalls())
            }
            "openUnknownSourcesSettings" -> {
                val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                    data = Uri.parse("package:${context.packageName}")
                }
                try {
                    context.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    Log.w(NATIVE_TAG, "openUnknownSourcesSettings failed: ${e.javaClass.simpleName}")
                    result.success(false)
                }
            }
            else -> return false
        }
        return true
    }

    /// Verify a downloaded update APK before installing it (plan 12–16):
    /// streaming SHA-256 of the file, plus the APK's signing-certificate
    /// SHA-256 (first signer) vs the running app's. Never throws — any
    /// failure returns a map with `error` set, so Dart never has to
    /// guess from a null.
    fun verifyApk(path: String, expectedSha256: String?): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        try {
            val file = File(path)
            if (!file.exists()) {
                out["error"] = "file not found"
                return out
            }
            val digest = MessageDigest.getInstance("SHA-256")
            FileInputStream(file).use { input ->
                val buffer = ByteArray(1024 * 64)
                var read: Int
                while (input.read(buffer).also { read = it } != -1) {
                    digest.update(buffer, 0, read)
                }
            }
            val sha256 = digest.digest().joinToString("") { "%02x".format(it) }
            out["sha256"] = sha256
            val checked = expectedSha256 != null
            out["sha256Checked"] = checked
            out["sha256Matches"] = checked &&
                sha256.equals(expectedSha256, ignoreCase = true)
            val apkFingerprint = apkSigningFingerprint(path)
            val currentFingerprint = currentSigningFingerprint()
            out["apkFingerprint"] = apkFingerprint
            out["currentFingerprint"] = currentFingerprint
            out["signatureMatches"] = apkFingerprint != null &&
                currentFingerprint != null &&
                apkFingerprint.equals(currentFingerprint, ignoreCase = true)
            if (apkFingerprint == null || currentFingerprint == null) {
                out["error"] = "signing certificate unavailable"
            }
            return out
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "verifyApk failed: ${e.javaClass.simpleName}")
            out["error"] = e.javaClass.simpleName
            return out
        }
    }

    /// Fire the system installer for [path] via a FileProvider URI.
    /// Returns false when the file is gone or the intent can't start —
    /// the caller keeps the downloaded APK (plan item 13) for a retry.
    fun installApk(path: String): Boolean {
        return try {
            val file = File(path)
            if (!file.exists()) return false
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "installApk failed: ${e.javaClass.simpleName}")
            false
        }
    }

    /// SHA-256 of the first signing certificate, lowercase hex — the
    /// same form as apksigner's `SHA-256 digest:` line and the
    /// `signing-fingerprint.txt` asset the update check caches.
    private fun certificateFingerprint(
        signatures: Array<android.content.pm.Signature>?,
    ): String? {
        val first = signatures?.firstOrNull() ?: return null
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(first.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    /// Signing fingerprint of a [PackageInfo]: v2/v3 signers first, then
    /// the v1 `signatures` fallback (an APK signed v1-only has no
    /// signingInfo).
    private fun packageInfoFingerprint(info: PackageInfo?): String? {
        if (info == null) return null
        val fromSigningInfo = certificateFingerprint(
            info.signingInfo?.apkContentsSigners,
        )
        if (fromSigningInfo != null) return fromSigningInfo
        @Suppress("DEPRECATION")
        return certificateFingerprint(info.signatures)
    }

    private fun currentSigningFingerprint(): String? {
        return try {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.packageManager.getPackageInfo(
                    context.packageName,
                    PackageManager.PackageInfoFlags.of(
                        PackageManager.GET_SIGNING_CERTIFICATES.toLong(),
                    ),
                )
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageInfo(
                    context.packageName,
                    PackageManager.GET_SIGNING_CERTIFICATES,
                )
            }
            packageInfoFingerprint(info)
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "currentSigningFingerprint failed: ${e.javaClass.simpleName}")
            null
        }
    }

    private fun apkSigningFingerprint(path: String): String? {
        return try {
            @Suppress("DEPRECATION")
            val info = context.packageManager.getPackageArchiveInfo(
                path,
                PackageManager.GET_SIGNING_CERTIFICATES,
            )
            packageInfoFingerprint(info)
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "apkSigningFingerprint failed: ${e.javaClass.simpleName}")
            null
        }
    }
}
