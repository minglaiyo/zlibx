package com.minglaiyo.zlibx

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Process
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Backup import restart (`zlibx/app_restart` channel): restart the
/// whole process so the freshly imported Hive boxes and providers
/// are re-read from scratch. (A widget-tree-only restart would leave
/// Hive boxes and Riverpod state holding pre-import data.)
class AppRestartHandler(
    private val context: Context,
) {

    /// Dispatches the app_restart methods this handler owns.
    /// Returns true when [call] was handled; false otherwise.
    fun handleMethod(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method != "restart") return false
        result.success(null)
        restartApp()
        return true
    }

    /// Restart the whole process: schedule the launcher activity via
    /// AlarmManager, then kill this process.
    fun restartApp() {
        val launch = context.packageManager
            .getLaunchIntentForPackage(context.packageName)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            } ?: return
        val pending = PendingIntent.getActivity(
            context, 0, launch,
            PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE,
        )
        val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarm.set(AlarmManager.RTC, System.currentTimeMillis() + 100, pending)
        Process.killProcess(Process.myPid())
    }
}
