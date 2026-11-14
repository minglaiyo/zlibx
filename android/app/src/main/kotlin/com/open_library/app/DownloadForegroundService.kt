package com.open_library.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * O1: foreground service that keeps the download process alive while a
 * download runs in the background.
 *
 * The Dart layer starts it when a download begins ([startDownload]) and
 * stops it when the last one ends ([endDownload]); it shows a progress
 * notification so the system does not reap the process while a download
 * is in flight. Progress text is pushed in from Dart via
 * [updateProgress]; the pause / cancel action buttons on the
 * notification report back through [onAction] so Dart can pause / cancel
 * the active download.
 *
 * Android 15+ caps dataSync foreground services at a cumulative time
 * limit per 24 h; when the system stops the service on that limit, the
 * Dart download is interrupted but its `.part` file is already on disk,
 * so the next start resumes from it (the resume mechanism needs no
 * change here).
 */
class DownloadForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "zlibx_download"
        private const val NOTIFICATION_ID = 1

        private const val ACTION_START = "start"
        private const val ACTION_PROGRESS = "progress"
        private const val ACTION_PAUSE = "pause"
        private const val ACTION_CANCEL = "cancel"

        /** Progress text the Dart layer pushes in (null = unknown). */
        @Volatile
        var progressText: String? = null
            private set

        /** Active download count. 0 → the service stops itself. */
        @Volatile
        var activeCount: Int = 0
            private set

        /** Callback Dart registers to receive pause / cancel actions. */
        @Volatile
        var onAction: ((String) -> Unit)? = null

        /** The running instance, so the companion's static entry points
            (invoked from MainActivity's channel before the service is
            started) can reach the instance methods. Set in [onCreate],
            cleared in [onDestroy]. */
        private var service: DownloadForegroundService? = null

        /** Start (or keep) the foreground service for a new download. */
        fun startDownload(context: Context) {
            activeCount++
            val intent = Intent(context, DownloadForegroundService::class.java)
                .setAction(ACTION_START)
            // START_STICKY: if the system kills the service, restart it so
            // an in-flight download is not silently lost (the .part file
            // keeps the bytes; the Dart side resumes on next start).
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** A download finished: drop the count, stop when it reaches 0. */
        fun endDownload(context: Context) {
            if (activeCount > 0) activeCount--
            if (activeCount <= 0) {
                activeCount = 0
                progressText = null
                context.stopService(
                    Intent(context, DownloadForegroundService::class.java),
                )
            }
        }

        /** Push a progress text from Dart (via the MainActivity channel). */
        fun updateProgress(text: String?) {
            progressText = text
            if (activeCount > 0) service?.notifyProgress()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startForegroundCompat()
            ACTION_PROGRESS -> {
                progressText = intent.getStringExtra("text")
                if (activeCount > 0) notifyProgress()
            }
            ACTION_PAUSE -> onAction?.invoke(ACTION_PAUSE)
            ACTION_CANCEL -> onAction?.invoke(ACTION_CANCEL)
        }
        return START_STICKY
    }

    override fun onCreate() {
        super.onCreate()
        service = this
        createChannel()
    }

    override fun onDestroy() {
        onAction = null
        service = null
        super.onDestroy()
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("zlibx")
            .setContentText(progressText ?: "下载中…")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(
                0, "暂停",
                actionPendingIntent(ACTION_PAUSE),
            )
            .addAction(
                0, "取消",
                actionPendingIntent(ACTION_CANCEL),
            )
            .build()
    }

    private fun notifyProgress() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun actionPendingIntent(action: String): PendingIntent {
        val intent = Intent(this, DownloadForegroundService::class.java)
            .setAction(action)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_IMMUTABLE else 0)
        return PendingIntent.getService(
            this,
            action.hashCode(),
            intent,
            flags,
        )
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "下载",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "后台下载进度"
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }
}
