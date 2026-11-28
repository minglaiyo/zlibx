package com.minglaiyo.zlibx

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Web keep-alive side (`zlibx/web_keepalive` channel): the foreground
/// service Dart starts/stops while the LAN book server runs, the shown
/// address, and the battery-optimization helpers behind the settings
/// entry ("exclude zlibx" is what makes the keep-alive bulletproof on
/// aggressive OEM builds — MIUI etc. kill even foreground services).
///
/// All calls are best-effort and synchronous. The [messenger] is set by
/// MainActivity in configureFlutterEngine before this channel is
/// registered, so setActionChannel can build the action channel on it.
class WebKeepaliveHandler(
    private val activity: Activity,
) {

    lateinit var messenger: BinaryMessenger

    /// Channel Dart listens on for the notification's Stop button.
    private var webActionChannel: MethodChannel? = null

    fun handleMethod(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "start" -> {
                WebKeepaliveService.start(activity, call.argument<String>("text") ?: "")
                result.success(null)
            }
            "stop" -> {
                WebKeepaliveService.stop(activity)
                result.success(null)
            }
            "updateText" -> {
                WebKeepaliveService.updateText(activity, call.argument<String>("text") ?: "")
                result.success(null)
            }
            "isIgnoringBatteryOptimization" -> {
                result.success(isIgnoringBatteryOptimizations())
            }
            "requestIgnoreBatteryOptimization" -> {
                requestIgnoreBatteryOptimizations()
                result.success(null)
            }
            "setActionChannel" -> {
                webActionChannel = MethodChannel(
                    messenger,
                    call.argument<String>("name")
                        ?: "zlibx/web_keepalive_action",
                )
                WebKeepaliveService.onAction = { action ->
                    webActionChannel?.invokeMethod(action, null)
                }
                result.success(null)
            }
            else -> return false
        }
        return true
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        return try {
            val pm = activity.getSystemService(PowerManager::class.java)
            pm.isIgnoringBatteryOptimizations(activity.packageName)
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "battery optimization check failed", e)
            false
        }
    }

    /// Fires the system dialog "Allow zlibx to ignore battery
    /// optimizations?" — a one-tap yes. Needs the
    /// REQUEST_IGNORE_BATTERY_OPTIMIZATIONS permission declared in the
    /// manifest (normal-level). No-op when already ignored.
    private fun requestIgnoreBatteryOptimizations() {
        if (isIgnoringBatteryOptimizations()) return
        try {
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${activity.packageName}"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(intent)
        } catch (e: Exception) {
            // Some OEM builds remove the dialog activity; the user can
            // still do it by hand through the app's system settings.
            Log.w(NATIVE_TAG, "battery optimization request failed", e)
        }
    }
}
