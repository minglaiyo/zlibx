package com.minglaiyo.zlibx

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Foreground service that keeps the LAN book server (the Dart
 * `HttpServer`) reachable while the screen is off.
 *
 * Screen-off was the one state the web service could not survive: Doze
 * pauses the CPU and parks the Wi-Fi radio, so a browser in another
 * room hit "could not load this book" mid-page and an interrupted ZIP
 * download died halfway. Dart starts this service when the server
 * starts ([start], the notification text is the address other devices
 * open) and stops it when the server stops ([stop]); while it runs the
 * service holds a partial wake lock (CPU) and a high-perf Wi-Fi lock
 * (radio), both renewed by a heartbeat well inside their timeout so a
 * missed renewal can never leak an awake device for more than ten
 * minutes.
 *
 * The notification has a Stop button reporting through [onAction]; the
 * service stops ITSELF first and then tells Dart, so it never outlives
 * its honesty: if the Dart engine is already gone the notification
 * still goes away. START_NOT_STICKY for the same reason — after a
 * process kill the HttpServer is gone, and a restarted idle service
 * would advertise a dead server. `specialUse` foreground-service type
 * (no dataSync time budget, which on Android 15+ would kill a long
 * reading session after ~6 h per 24 h): sideloaded app, no store
 * review, the subtype is declared in the manifest.
 */
class WebKeepaliveService : Service() {

    companion object {
        private const val CHANNEL_ID = "zlibx_web"
        private const val NOTIFICATION_ID = 2
        private const val ACTION_START = "start"
        private const val ACTION_STOP = "stop"

        // The locks self-expire in 10 minutes; the heartbeat renews both
        // every 4. A stop path that misses onDestroy can never leave the
        // device awake for longer than one timeout.
        private const val LOCK_TIMEOUT_MS = 10 * 60 * 1000L
        private const val HEARTBEAT_MS = 4 * 60 * 1000L

        private val stateLock = Any()
        private var wakeLock: PowerManager.WakeLock? = null
        private var wifiLock: WifiManager.WifiLock? = null

        /** The address text the Dart layer pushed in (shown as-is). */
        @Volatile
        var statusText: String? = null
            private set

        /** Callback Dart registers to receive the notification's Stop. */
        @Volatile
        var onAction: ((String) -> Unit)? = null

        /** The running instance, so the companion's static entry points
            (invoked from MainActivity's channel before the service is
            started) can reach the instance methods. Set in [onCreate],
            cleared in [onDestroy]. */
        private var service: WebKeepaliveService? = null

        /** Start (or refresh) the keep-alive for the running server. */
        fun start(context: Context, text: String) {
            synchronized(stateLock) {
                statusText = text
                val intent = Intent(context, WebKeepaliveService::class.java)
                    .setAction(ACTION_START)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            }
        }

        /** The server stopped: drop everything. Harmless if not running. */
        fun stop(context: Context) {
            synchronized(stateLock) {
                statusText = null
                releaseLocksLocked()
                context.stopService(
                    Intent(context, WebKeepaliveService::class.java),
                )
            }
        }

        /** Refresh the shown address (the hotspot address changes when
            the hotspot is re-enabled) and renew the locks. */
        fun updateText(context: Context, text: String) {
            synchronized(stateLock) {
                statusText = text
                service?.let {
                    renewLocksLocked(it)
                    it.notifyStatus()
                }
            }
        }

        // Caller holds stateLock. The wake lock is bounded by
        // [LOCK_TIMEOUT_MS] and renewed by the heartbeat before it
        // lapses. The Wi-Fi lock has no timeout overload on this API
        // level (acquire(long) is API 34+), so it is held for the
        // service's whole life and released by every stop path — all of
        // them funnel through onDestroy; a process kill lets the kernel
        // drop both locks with the process.
        private fun renewLocksLocked(context: Context) {
            val pm = context.getSystemService(PowerManager::class.java)
            val lock = wakeLock
                ?: pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "zlibx:web")
                    .apply { setReferenceCounted(false) }
                    .also { wakeLock = it }
            lock.acquire(LOCK_TIMEOUT_MS)

            val wifi = context.getSystemService(WifiManager::class.java)
            val wLock = wifiLock
                ?: wifi.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "zlibx:web",
                ).apply { setReferenceCounted(false) }
                    .also { wifiLock = it }
            if (!wLock.isHeld) wLock.acquire()
        }

        private fun releaseLocksLocked() {
            wakeLock?.let { if (it.isHeld) it.release() }
            wakeLock = null
            wifiLock?.let { if (it.isHeld) it.release() }
            wifiLock = null
        }
    }

    /** Renews both locks while the service exists (it exists only while
        the server runs). Main thread, negligible cost. The tick re-posts
        only while the instance lives — after onDestroy clears [service]
        a straggling tick must not reschedule itself forever. */
    private val heartbeat = Handler(Looper.getMainLooper())
    private val heartbeatTick = object : Runnable {
        override fun run() {
            val active = synchronized(stateLock) { service }
            if (active == null) return
            synchronized(stateLock) { renewLocksLocked(active) }
            heartbeat.postDelayed(this, HEARTBEAT_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        synchronized(stateLock) { service = this }
        createChannel()
        heartbeat.postDelayed(heartbeatTick, HEARTBEAT_MS)
    }

    override fun onDestroy() {
        heartbeat.removeCallbacks(heartbeatTick)
        synchronized(stateLock) {
            releaseLocksLocked()
            onAction = null
            service = null
        }
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_NOT_STICKY (same reasoning as DownloadForegroundService):
        // a null intent arrives only after a process kill, when the
        // HttpServer is gone and a restarted service would advertise a
        // dead server.
        if (intent == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        when (intent.action) {
            ACTION_START -> {
                startForegroundCompat()
                synchronized(stateLock) { renewLocksLocked(this) }
            }
            ACTION_STOP -> {
                // The notification button: stop THIS service first (so a
                // dead engine cannot leave an orphan notice advertising a
                // dead server), then let Dart stop the HttpServer.
                synchronized(stateLock) { releaseLocksLocked() }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf(startId)
                try {
                    onAction?.invoke(ACTION_STOP)
                } catch (e: Exception) {
                    android.util.Log.w(NATIVE_TAG, "web stop dispatch failed", e)
                }
            }
        }
        return START_NOT_STICKY
    }

    /** 划掉应用：Activity 随任务销毁，Flutter 引擎与 Dart HttpServer
        一起死，而持前台服务的进程继续活着——服务成为孤儿，通知栏
        会一直宣称一个已经不存在的服务。停服务、放锁、撤通知。 */
    override fun onTaskRemoved(rootIntent: Intent?) {
        heartbeat.removeCallbacks(heartbeatTick)
        synchronized(stateLock) {
            releaseLocksLocked()
            statusText = null
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

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // specialUse: no dataSync time budget (Android 15+ would end
            // a long reading session after ~6 h). The subtype is declared
            // in the manifest under PROPERTY_SPECIAL_USE_FGS_SUBTYPE.
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("zlibx")
            .setContentText(statusText ?: "")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        // getLaunchIntentForPackage is null for tasks Android refuses to
        // launch (never seen in practice); a null content intent beats a
        // crash in a service that must not die.
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch != null) {
            builder.setContentIntent(launchPendingIntent(launch))
        }
        return builder.addAction(0, "停止", stopPendingIntent()).build()
    }

    private fun notifyStatus() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun launchPendingIntent(launch: Intent): PendingIntent {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(
            this,
            "web_keepalive".hashCode(),
            launch,
            flags,
        )
    }

    private fun stopPendingIntent(): PendingIntent {
        val intent = Intent(this, WebKeepaliveService::class.java)
            .setAction(ACTION_STOP)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getService(
            this,
            ACTION_STOP.hashCode(),
            intent,
            flags,
        )
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "书籍服务",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "局域网书籍服务的常驻通知"
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }
}
