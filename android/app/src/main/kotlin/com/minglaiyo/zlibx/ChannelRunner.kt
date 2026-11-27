package com.minglaiyo.zlibx

import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/// Log tag shared by every native handler in this package. Kept
/// identical to the old MainActivity tag so `adb logcat -s
/// ZlibxMediaStore` keeps working after the split.
internal const val NATIVE_TAG = "ZlibxMediaStore"

/// A native failure that must reach Dart as a platform error instead
/// of a silent null / false (review v2 P1-2). [code] is the stable,
/// machine-readable reason Dart maps on; [message] is a fixed literal
/// written at the throw site — never an exception message, which can
/// carry file paths (AppLog.report prints Dart-side errors to the
/// release log). The full exception stays in logcat here, under
/// [NATIVE_TAG], for diagnosis.
internal class ChannelFailure(val code: String, message: String?) :
    Exception(message)

/// Owns the worker pools and the MethodChannel reply discipline for
/// every native handler (review v2 P1-2 + P1-3).
///
/// One pool per concern, so a slow job in one area cannot stall
/// another:
/// - [ioExecutor]: single thread — file copies (publish to Downloads,
///   copy to cache). Ordered, never on the platform thread.
/// - [lightExecutor]: 2 threads — cheap ContentResolver probes
///   (exists / delete / real path / tree listing).
/// - [pendingExecutor]: single thread — every operation on a pending
///   download entry, in Dart-sent order (see PendingDownloadHandler).
/// - [hashExecutor]: single thread — MD5 of large files only, so a
///   multi-hundred-MB hash never queues behind (or blocks) a share
///   copy on [ioExecutor].
///
/// The Activity owns the lifecycle: it creates one runner and calls
/// [shutdown] from onDestroy. Handlers never shut a pool down.
class ChannelRunner(
    private val postToMain: (Runnable) -> Unit,
) {

    // File copies (publish to Downloads, copy to cache) can move hundreds
    // of MB; they must not run on the platform (UI) thread or the app
    // freezes / ANRs. A single worker keeps them ordered.
    val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    // Cheap ContentResolver probes (exists / delete) get their own small
    // pool so they never queue behind a multi-hundred-MB copy.
    val lightExecutor: ExecutorService = Executors.newFixedThreadPool(2)

    // Every operation on a pending download entry (append / size /
    // finish / abort) runs on this one thread, in the order Dart sent
    // them. That ordering is what makes the held-open streams safe:
    // a size query or an abort can never overtake a write that was sent
    // before it. Kept apart from [ioExecutor] so a long share / publish
    // copy never stalls a download.
    val pendingExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    // MD5 of a download product only. A few-hundred-MB file must not
    // block a share copy (or queue behind one) on [ioExecutor].
    val hashExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    /// Runs [block] on [executor] and replies on the main thread.
    ///
    /// P1-2: a failure is no longer swallowed to null. A [ChannelFailure]
    /// answers `result.error` with its own code; any other Exception
    /// answers `result.error` with [errorCode] and the exception's
    /// class name as the message (never the exception message itself —
    /// see [ChannelFailure]). Dart already funnels every one of these
    /// calls through a PlatformException catch that returns the same
    /// null / false fallback as before, except writePendingChunk,
    /// whose Dart side rethrows so the writer can record the code.
    ///
    /// The `execute` call itself is also guarded: after [shutdown]
    /// it throws RejectedExecutionException, which used to escape the
    /// MethodCallHandler uncaught. A rejected task now answers
    /// `channel_shutdown` instead of crashing.
    fun <T> runAsync(
        result: MethodChannel.Result,
        executor: ExecutorService,
        errorCode: String,
        block: () -> T?,
    ) {
        val task = Runnable {
            try {
                val value = block()
                replySuccess(result, value)
            } catch (e: ChannelFailure) {
                Log.w(NATIVE_TAG, "Channel task failed: ${e.code}")
                replyError(result, e.code, e.message ?: e.code)
            } catch (e: Exception) {
                Log.w(NATIVE_TAG, "Channel task failed", e)
                replyError(result, errorCode, e.javaClass.simpleName)
            }
        }
        try {
            executor.execute(task)
        } catch (e: RejectedExecutionException) {
            // The pools are shut down in onDestroy; a call that arrives
            // after that (in-flight across an activity recreate, or
            // after the engine detached) must be answered, not crash.
            Log.w(NATIVE_TAG, "Channel task rejected after shutdown", e)
            replyError(result, "channel_shutdown", "executor shut down")
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "Channel task not scheduled", e)
            replyError(result, "channel_shutdown", e.javaClass.simpleName)
        }
    }

    /// Best-effort fire-and-forget work (startup cleanup, onDestroy
    /// stream close). Returns false when the pool is already shut
    /// down instead of throwing.
    fun tryExecute(executor: ExecutorService, block: () -> Unit): Boolean {
        return try {
            executor.execute(block)
            true
        } catch (e: Exception) {
            Log.w(NATIVE_TAG, "Task not scheduled", e)
            false
        }
    }

    /// Close the pending streams on [pendingExecutor], then shut every
    /// pool down. shutdown() lets a running copy finish; it only
    /// rejects new work. Called once, from the Activity's onDestroy.
    fun shutdown(closePendingStreams: () -> Unit) {
        tryExecute(pendingExecutor) { closePendingStreams() }
        pendingExecutor.shutdown()
        // shutdown() lets a running copy finish; it only rejects new work.
        ioExecutor.shutdown()
        lightExecutor.shutdown()
        hashExecutor.shutdown()
    }

    private fun replySuccess(result: MethodChannel.Result, value: Any?) {
        postToMain(Runnable {
            try {
                result.success(value)
            } catch (e: IllegalStateException) {
                // Engine detached while the work was running.
                Log.w(NATIVE_TAG, "reply after detach ignored", e)
            }
        })
    }

    private fun replyError(
        result: MethodChannel.Result,
        code: String,
        message: String,
    ) {
        postToMain(Runnable {
            try {
                result.error(code, message, null)
            } catch (e: IllegalStateException) {
                // Engine detached while the work was running.
                Log.w(NATIVE_TAG, "error reply after detach ignored", e)
            }
        })
    }
}
