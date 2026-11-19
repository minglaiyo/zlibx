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
 * limit per 24 h; [onTimeout] pauses every download through [onAction]
 * (the `.part` + `.meta` files make the next start resume), stops the
 * service and leaves a notification pointing the user back to the app.
 * The service is START_NOT_STICKY: after a process kill the Dart engine
 * is gone, and resume lives in Dart on next launch — a restarted idle
 * service would own nothing to do.
 */
class DownloadForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "zlibx_download"
        private const val NOTIFICATION_ID = 1
        private const val DONE_CHANNEL_ID = "zlibx_done"

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

        /** E3: post a completion notification tapping straight into the
            book (content:// URI + ACTION_VIEW with a read grant). Plain
            file paths get a notification without a tap target — modern
            Android blocks file:// intents without a FileProvider, and the
            book is still one tap away in the downloads tab. Runs from the
            app process; POST_NOTIFICATIONS gates visibility, best-effort.
            Notification id is stable per book so a re-download replaces
            its old notice instead of stacking. */
        fun notifyCompleted(
            context: Context,
            title: String,
            uri: String,
            mimeType: String,
            detail: String,
        ) {
            try {
                val nm = context.getSystemService(NotificationManager::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    nm.createNotificationChannel(
                        NotificationChannel(
                            DONE_CHANNEL_ID,
                            "下载完成",
                            NotificationManager.IMPORTANCE_DEFAULT,
                        ).apply { description = "书籍下载完成提醒" },
                    )
                }
                val builder = NotificationCompat.Builder(context, DONE_CHANNEL_ID)
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setContentTitle(title)
                    .setContentText(detail)
                    .setAutoCancel(true)
                if (uri.startsWith("content://")) {
                    val openIntent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(android.net.Uri.parse(uri), mimeType)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        PendingIntent.FLAG_IMMUTABLE
                    builder.setContentIntent(
                        PendingIntent.getActivity(
                            context,
                            uri.hashCode(),
                            openIntent,
                            flags,
                        ),
                    )
                }
                nm.notify(uri.hashCode(), builder.build())
            } catch (e: Exception) {
                android.util.Log.w("ZlibxDownload", "completion notification failed", e)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_NOT_STICKY (审查 A2): a restart after a process kill used
        // to deliver a null-intent service with activeCount == 0 and no
        // Dart engine — an idle, self-restarting foreground service. The
        // real resume lives in Dart (history + .part on next launch), so
        // there is nothing for a sticky restart to recover.
        if (intent == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        when (intent.action) {
            ACTION_START -> startForegroundCompat()
            ACTION_PROGRESS -> {
                progressText = intent.getStringExtra("text")
                if (activeCount > 0) notifyProgress()
            }
            ACTION_PAUSE -> onAction?.invoke(ACTION_PAUSE)
            ACTION_CANCEL -> onAction?.invoke(ACTION_CANCEL)
        }
        return START_NOT_STICKY
    }

    /**
     * Android 15+ (审查 A1): a dataSync foreground service accumulates a
     * time budget (~6 h per 24 h); on exceeding it the system calls this
     * and expects the service to come down. Pause EVERY download through
     * the existing action channel (the Dart handler loops all cancel
     * tokens — .part + .meta survive), stop the service, and leave one
     * notification explaining why and where to continue.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        activeCount = 0
        progressText = null
        try {
            onAction?.invoke(ACTION_PAUSE)
        } catch (e: Exception) {
            android.util.Log.w("ZlibxDownload", "timeout pause dispatch failed", e)
        }
        stopSelf(startId)
        showTimeoutNotice()
    }

    private fun showTimeoutNotice() {
        try {
            val nm = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        DONE_CHANNEL_ID,
                        "下载完成",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ).apply { description = "书籍下载完成提醒" },
                )
            }
            val openApp = packageManager.getLaunchIntentForPackage(packageName)
            val builder = NotificationCompat.Builder(this, DONE_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle("下载已被系统暂停")
                .setContentText("后台下载时长达到系统上限；全部任务已暂停，回到应用点继续即可续传")
                .setAutoCancel(true)
            if (openApp != null) {
                builder.setContentIntent(
                    PendingIntent.getActivity(
                        this,
                        "timeout".hashCode(),
                        openApp,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            }
            nm.notify("timeout".hashCode(), builder.build())
        } catch (e: Exception) {
            android.util.Log.w("ZlibxDownload", "timeout notice failed", e)
        }
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
