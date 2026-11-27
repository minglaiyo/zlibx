package com.minglaiyo.zlibx

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Background-download side (`zlibx/download_service` channel):
/// the foreground service Dart starts/stops, progress pushes, and
/// the channel Dart listens on for pause/cancel actions fired by
/// the foreground-service notification (O1).
///
/// All calls are best-effort and synchronous, except MD5 (below).
/// The [messenger] is set by MainActivity in configureFlutterEngine
/// before this channel is registered, so setActionChannel can build
/// the action channel on it.
class DownloadServiceHandler(
    private val activity: Activity,
    private val runner: ChannelRunner,
    private val hashHandler: HashHandler,
) {

    lateinit var messenger: BinaryMessenger

    /// Channel Dart listens on for download pause/cancel actions fired by
    /// the foreground-service notification (O1). Set when Dart registers
    /// its action handler.
    private var downloadActionChannel: MethodChannel? = null

    /// Registers the download_service channel. Returns true when
    /// [call] was handled; false otherwise. Kept separate from the
    /// other handlers' handleMethod because the channel itself is
    /// registered here (it needs the messenger).
    fun handleMethod(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "requestNotificationPermission" -> {
                requestNotificationPermission()
                result.success(null)
            }
            "start" -> {
                DownloadForegroundService.startDownload(activity)
                result.success(null)
            }
            "stop" -> {
                DownloadForegroundService.endDownload(activity)
                result.success(null)
            }
            "cancelStale" -> {
                // 新引擎启动：清掉上一个引擎留下的孤儿服务/通知。
                DownloadForegroundService.cancelStale(activity)
                result.success(null)
            }
            "md5OfContent" -> {
                // 外部源下载完成后的内容校验（审查 5.1）：流式
                // MD5 在专用的 hash 线程池上跑——几百 MB 的文件不能占
                // 主线程，也不能阻塞分享复制；算完回主线程答 result。
                // P1-2: the old code did a bare ioExecutor.execute with
                // no try/catch and an unguarded result.success, so a
                // post-onDestroy call threw RejectedExecutionException
                // (or IllegalStateException after detach) uncaught.
                // It now goes through the runner.
                val target = call.argument<String>("uri") ?: ""
                runner.runAsync(result, runner.hashExecutor, "md5_failed") {
                    hashHandler.md5OfContent(target)
                }
            }
            "updateProgress" -> {
                DownloadForegroundService.updateProgress(
                    call.argument<String>("text"),
                )
                result.success(null)
            }
            "notifyCompleted" -> {
                // E3+F4: 完成通知（副文本带当日剩余额度），点击直达文件。
                DownloadForegroundService.notifyCompleted(
                    activity,
                    call.argument<String>("title") ?: "zlibx",
                    call.argument<String>("uri") ?: "",
                    call.argument<String>("mimeType") ?: "*/*",
                    call.argument<String>("detail") ?: "下载完成",
                )
                result.success(null)
            }
            "setActionChannel" -> {
                downloadActionChannel = MethodChannel(
                    messenger,
                    call.argument<String>("name")
                        ?: "zlibx/download_service_action",
                )
                DownloadForegroundService.onAction = { action ->
                    downloadActionChannel?.invokeMethod(action, null)
                }
                result.success(null)
            }
            else -> return false
        }
        return true
    }

    /// O1: request POST_NOTIFICATIONS on Android 13+ so the download
    /// progress notification is visible. Best-effort — the foreground
    /// service runs regardless; the notification is only suppressed
    /// without the grant.
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (activity.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        try {
            activity.requestPermissions(
                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                0,
            )
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "notification permission request failed", e)
        }
    }
}
