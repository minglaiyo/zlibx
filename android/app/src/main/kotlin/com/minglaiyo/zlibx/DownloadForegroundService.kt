package com.minglaiyo.zlibx

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
import android.os.PowerManager
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
        private const val WAKE_LOCK_TIMEOUT_MS = 10 * 60 * 1000L

        // Count transitions and wake-lock operations share one lock so an
        // end/start race cannot leave a lock held after the count reaches 0.
        private val stateLock = Any()
        private var activeDownloads = 0
        private var wakeLock: PowerManager.WakeLock? = null

        private const val ACTION_START = "start"
        private const val ACTION_PROGRESS = "progress"
        private const val ACTION_PAUSE = "pause"
        private const val ACTION_CANCEL = "cancel"

        /** Progress text the Dart layer pushes in (null = unknown). */
        @Volatile
        var progressText: String? = null
            private set

        /** Active download count. 0 → the service stops itself. */
        val activeCount: Int
            get() = synchronized(stateLock) { activeDownloads }

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
            synchronized(stateLock) {
                activeDownloads++
                renewWakeLockLocked(context)
                val intent = Intent(context, DownloadForegroundService::class.java)
                    .setAction(ACTION_START)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            }
        }

        /** A download finished: drop the count, stop when it reaches 0. */
        fun endDownload(context: Context) {
            synchronized(stateLock) {
                if (activeDownloads > 0) activeDownloads--
                if (activeDownloads <= 0) {
                    activeDownloads = 0
                    progressText = null
                    releaseWakeLockLocked()
                    context.stopService(
                        Intent(context, DownloadForegroundService::class.java),
                    )
                }
            }
        }

    /** Push a progress text from Dart (via the MainActivity channel). */
    fun updateProgress(text: String?) {
        progressText = text
        synchronized(stateLock) {
            if (activeDownloads > 0) {
                service?.let {
                    renewWakeLockLocked(it)
                    it.notifyProgress()
                }
            }
        }
    }

    /** 新引擎启动时的陈旧清理（2026-11-21 下载中断修复）：上一个
        Dart 引擎死掉后（划掉应用之外的死法——系统低内存回收 Activity
        等），前台服务与"下载中 X%"的通知可能成为孤儿。新引擎手里没
        有任何任务，服务必然无事可做：停服务 + 撤进度通知。没有孤儿
        时是无害 no-op。下载本身的恢复走 Dart 侧对盘上 .part 残片的
        扫描（DownloadNotifier 启动恢复）。 */
    fun cancelStale(context: Context) {
        synchronized(stateLock) {
            activeDownloads = 0
            progressText = null
            releaseWakeLockLocked()
            try {
                context.stopService(
                    Intent(context, DownloadForegroundService::class.java),
                )
            } catch (e: Exception) {
                android.util.Log.w("ZlibxDownload", "stale stop failed", e)
            }
        }
        try {
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.cancel(NOTIFICATION_ID)
        } catch (e: Exception) {
            android.util.Log.w("ZlibxDownload", "stale cancel failed", e)
        }
    }

    // Caller holds stateLock. A timeout bounds battery use if a stop path
    // is ever missed; each progress update renews it.
    private fun renewWakeLockLocked(context: Context) {
        if (activeDownloads == 0) return
        val lock = wakeLock ?: context.getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "zlibx:download")
            .apply { setReferenceCounted(false) }
            .also { wakeLock = it }
        lock.acquire(WAKE_LOCK_TIMEOUT_MS)
    }

    private fun releaseWakeLockLocked() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
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

    /**
     * 划掉应用（2026-11-21 下载中断修复）：Activity 随任务销毁，
     * Flutter 引擎与 Dart 下载引擎一起死，而持有前台服务的进程继续
     * 活着——服务成为孤儿，"下载中 X%"的通知永远钉在通知栏上，暂停/
     * 取消按钮指向已死的引擎。这里停服务并撤通知，让通知栏回到诚实
     * 的状态：此刻确实没有任何下载在跑。.part / .meta / pending 条
     * 目都在盘上，下次启动由 Dart 侧的启动恢复把任务挂回下载页。
     * onAction 尽力而为：引擎若还有一息，暂停能把缓冲刷进盘上；已
     * 死则调用落进 dead messenger，失败只记日志。
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        synchronized(stateLock) {
            activeDownloads = 0
            progressText = null
            releaseWakeLockLocked()
        }
        try {
            onAction?.invoke(ACTION_PAUSE)
        } catch (e: Exception) {
            android.util.Log.w("ZlibxDownload", "task-removed pause failed", e)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

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
            ACTION_START -> {
                startForegroundCompat()
                synchronized(stateLock) {
                    if (activeDownloads > 0) {
                        renewWakeLockLocked(this)
                    } else {
                        stopSelf(startId)
                    }
                }
            }
            ACTION_PROGRESS -> {
                progressText = intent.getStringExtra("text")
                synchronized(stateLock) {
                    if (activeDownloads > 0) {
                        renewWakeLockLocked(this)
                        notifyProgress()
                    }
                }
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
        synchronized(stateLock) {
            activeDownloads = 0
            progressText = null
            releaseWakeLockLocked()
        }
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
        synchronized(stateLock) {
            service = this
            if (activeDownloads > 0) renewWakeLockLocked(this)
        }
        createChannel()
    }

    override fun onDestroy() {
        synchronized(stateLock) {
            activeDownloads = 0
            releaseWakeLockLocked()
            onAction = null
            service = null
        }
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
