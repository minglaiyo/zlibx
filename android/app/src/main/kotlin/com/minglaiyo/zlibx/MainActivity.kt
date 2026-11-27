package com.minglaiyo.zlibx

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity instead of FlutterActivity: the privacy
// lock's local_auth (BiometricPrompt) requires a FragmentActivity —
// FlutterActivity makes the biometric plugin throw on every call.
//
// Review v2 P1-3: this Activity only registers channels and owns
// the Activity lifecycle (permissions, the SAF folder picker,
// onCreate / onDestroy). All work lives in the handlers:
// - MediaStoreHandler — publish + content:// ops
// - PendingDownloadHandler — pending entries + held streams
// - ShareHandler — copy to cache + stale share cleanup
// - HashHandler — MD5 (own pool, see ChannelRunner)
// - SafHandler — SAF tree walk / copy / delete / grants
// - NetworkStateHandler — lanAddressInfo facts
// - DownloadServiceHandler — foreground-service channel
// - AppInstallHandler — APK verify + install
// - AppRestartHandler — process restart after backup import
// Channel names and method names are unchanged, so no Dart call
// site changes.
class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val CHANNEL = "zlibx/media_store"
        private const val TAG = NATIVE_TAG

        /// Request code for the Android 17 local-network permission
        /// (ACCESS_LOCAL_NETWORK), asked from the local-network channel.
        private const val REQUEST_LOCAL_NETWORK = 1001
    }

    private val runner = ChannelRunner { runOnUiThread(it) }

    private val mediaStoreHandler = MediaStoreHandler(this, runner)
    private val pendingDownloadHandler = PendingDownloadHandler(this, runner)
    private val shareHandler = ShareHandler(this, runner)
    private val hashHandler = HashHandler(this)
    private val safHandler = SafHandler(this, runner, shareHandler)
    private val networkStateHandler = NetworkStateHandler(this, runner)
    private val downloadServiceHandler =
        DownloadServiceHandler(this, runner, hashHandler)
    private val appInstallHandler = AppInstallHandler(this, runner)
    private val appRestartHandler = AppRestartHandler(this)

    /// Pending reply for an in-flight local-network permission
    /// request. Only one may be outstanding; a second call while one
    /// is in flight is answered false at once (the caller retries).
    private var pendingLocalNetworkResult: MethodChannel.Result? = null

    /// Pending reply for an in-flight SAF folder pick. Only one may
    /// be outstanding; a second call while one is in flight is
    /// answered null at once (the caller retries).
    private var pendingTreePickResult: MethodChannel.Result? = null

    /// SAF folder picker (ACTION_OPEN_DOCUMENT_TREE). Registered as a
    /// property so it exists before onStart; StartActivityForResult
    /// (not OpenDocumentTree) so the intent can carry EXTRA_INITIAL_URI
    /// pointing at Download/zlibx. The picked tree URI is persisted
    /// (takePersistableUriPermission) and returned to Dart, which
    /// stores it; a cancel answers null.
    private val treePicker = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { outcome ->
        val pending = pendingTreePickResult
        pendingTreePickResult = null
        if (pending == null) return@registerForActivityResult
        val uri = if (outcome.resultCode == Activity.RESULT_OK) {
            outcome.data?.data
        } else {
            null
        }
        if (uri == null) {
            replyTreePick(pending, null)
            return@registerForActivityResult
        }
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            replyTreePick(pending, uri.toString())
        } catch (e: Exception) {
            // The picker did not grant a persistable permission: the
            // tree could not be re-adopted after a restart, so treat
            // the pick as failed.
            Log.w(TAG, "takePersistableUriPermission failed", e)
            replyTreePick(pending, null)
        }
    }

    /// Answer the pending tree-pick reply, tolerating an engine that
    /// detached while the picker was up (same pattern as the
    /// local-network reply).
    private fun replyTreePick(result: MethodChannel.Result, uri: String?) {
        try {
            result.success(uri)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "tree pick reply after detach ignored", e)
        }
    }

    override fun onDestroy() {
        // Close any held pending streams (entries stay IS_PENDING and
        // resumable), then let queued work drain. The runner answers
        // any call that arrives after the pools shut down with
        // `channel_shutdown` instead of throwing RejectedExecution-
        // Exception out of the MethodCallHandler (review v2 P1-2).
        runner.shutdown { pendingDownloadHandler.closeAllPendingStreams() }
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_LOCAL_NETWORK) return
        // Answer the Dart call that asked for the local-network
        // permission (see "ensureLocalNetworkPermission" below).
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        try {
            pendingLocalNetworkResult?.success(granted)
        } catch (e: IllegalStateException) {
            // Engine detached while the dialog was up.
            Log.w(TAG, "local network reply after detach ignored", e)
        }
        pendingLocalNetworkResult = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // O9: a share's temp copy lingered until the NEXT share (the old
        // code only cleaned before a new copy). Drop stale share_ files
        // at startup too, when no share from this process can be in
        // flight. One hour, not 24: a share target reads the file
        // within seconds of the share.
        runner.tryExecute(runner.ioExecutor) {
            shareHandler.cleanupStaleShareFiles(60L * 60L * 1000L)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        downloadServiceHandler.messenger = messenger

        MethodChannel(messenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when {
                    mediaStoreHandler.handleMethod(call, result) -> Unit
                    pendingDownloadHandler.handleMethod(call, result) -> Unit
                    shareHandler.handleMethod(call, result) -> Unit
                    safHandler.handleMethod(call, result) -> Unit
                    call.method == "pickDownloadTree" -> {
                        // SAF folder pick: the folder picker is a
                        // system UI, so this runs on the platform
                        // thread (never runAsync). The answer arrives
                        // later, through the launcher callback.
                        if (pendingTreePickResult != null) {
                            result.success(null)
                        } else {
                            pendingTreePickResult = result
                            treePicker.launch(safHandler.treePickIntent())
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Web service: structured network state for the address picker.
        // Dart does the selection; this only reports facts.
        MethodChannel(messenger, "zlibx/network_state")
            .setMethodCallHandler { call, result ->
                if (!networkStateHandler.handleMethod(call, result)) {
                    result.notImplemented()
                }
            }

        // Web service: the Android 17 local-network permission only.
        // The HTTP server itself is a Dart HttpServer now (the native
        // LanWebServer rewrite was reverted — the socket was never the
        // problem, the missing permission was). Dart asks here before
        // binding, so other devices can actually reach the server.
        // Stays in the Activity: requesting a permission and answering
        // onRequestPermissionsResult are Activity lifecycle, not a
        // handler's job.
        MethodChannel(messenger, "zlibx/local_network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ensureLocalNetworkPermission" -> {
                        // Android 17+ (targetSdk 37) blocks local-network
                        // sockets without ACCESS_LOCAL_NETWORK: without it,
                        // inbound TCP from other devices times out in the
                        // network stack, before the SYN reaches our socket.
                        // Below API 37 the gate does not exist.
                        if (Build.VERSION.SDK_INT < 37) {
                            result.success(true)
                        } else if (ContextCompat.checkSelfPermission(
                                this,
                                Manifest.permission.ACCESS_LOCAL_NETWORK,
                            ) == PackageManager.PERMISSION_GRANTED
                        ) {
                            result.success(true)
                        } else if (pendingLocalNetworkResult != null) {
                            result.success(false)
                        } else {
                            pendingLocalNetworkResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.ACCESS_LOCAL_NETWORK),
                                REQUEST_LOCAL_NETWORK,
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // O1: background download keep-alive. Dart starts/stops the
        // foreground service, pushes progress, and registers the channel
        // it listens on for pause/cancel actions from the notification.
        MethodChannel(messenger, "zlibx/download_service")
            .setMethodCallHandler { call, result ->
                if (!downloadServiceHandler.handleMethod(call, result)) {
                    result.notImplemented()
                }
            }

        // Backup import: restart the whole process so the freshly
        // imported Hive boxes and providers are re-read from scratch.
        MethodChannel(messenger, "zlibx/app_restart")
            .setMethodCallHandler { call, result ->
                if (!appRestartHandler.handleMethod(call, result)) {
                    result.notImplemented()
                }
            }

        // In-app update install (plan 12–16): verify the downloaded APK
        // (streaming SHA-256 + signing certificate vs the running app)
        // and fire the system installer. Verification reads the file on
        // ioExecutor; the install intent fires on the platform thread.
        MethodChannel(messenger, "zlibx/app_install")
            .setMethodCallHandler { call, result ->
                if (!appInstallHandler.handleMethod(call, result)) {
                    result.notImplemented()
                }
            }
    }
}
