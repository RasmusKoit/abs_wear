package dev.koit.abs_wear

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log

/**
 * Keeps a book download going with the screen off.
 *
 * The download itself runs in Dart. While it does, this foreground service
 * keeps the process alive, holds a wake lock so the CPU doesn't sleep, and
 * shows a notification with the progress and a cancel action.
 * [DownloadNetwork] moves the download onto Wi-Fi.
 */
class DownloadService : Service() {

    companion object {
        private const val TAG = "DownloadService"
        private const val CHANNEL_ID = "downloads"
        private const val NOTIFICATION_ID = 7301
        private const val ACTION_CANCEL = "dev.koit.abs_wear.CANCEL_DOWNLOAD"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_CANCEL = "cancel"
        private const val EXTRA_CHANNEL = "channel"

        /** Called on the main thread when the notification's cancel is tapped. */
        var onCancel: (() -> Unit)? = null

        private var instance: DownloadService? = null
        private var title = ""
        private var cancelLabel = ""
        private var percent = 0

        /** Labels come from Dart, so the notification uses the app's language. */
        fun start(context: Context, title: String, cancelLabel: String, channelName: String) {
            this.title = title
            this.cancelLabel = cancelLabel
            percent = 0
            val intent = Intent(context, DownloadService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_CANCEL, cancelLabel)
                .putExtra(EXTRA_CHANNEL, channelName)
            try {
                context.startForegroundService(intent)
            } catch (e: RuntimeException) {
                // Not allowed from the background: the download still runs,
                // it just may stall once the screen is off.
                Log.w(TAG, "Could not start the download service", e)
            }
        }

        fun progress(percent: Int) {
            if (percent == this.percent) return
            this.percent = percent
            instance?.showNotification()
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DownloadService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        wakeLock = getSystemService(PowerManager::class.java)
            ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "abs_wear:download")
            ?.apply {
                setReferenceCounted(false)
                // A safety net: Dart releases it when the download ends.
                acquire(6 * 60 * 60 * 1000L)
            }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            onCancel?.invoke()
            // Torn down here too, so Cancel works when no Dart download is
            // left to do it. Dart's own stop afterwards is a no-op.
            DownloadNetwork.release(this)
            // Not stopSelf(): a newer download's start may be queued.
            stopSelf(startId)
            return START_NOT_STICKY
        }
        intent?.getStringExtra(EXTRA_TITLE)?.let { title = it }
        intent?.getStringExtra(EXTRA_CANCEL)?.let { cancelLabel = it }
        getSystemService(NotificationManager::class.java)?.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                intent?.getStringExtra(EXTRA_CHANNEL) ?: "Downloads",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
        try {
            startForeground(
                NOTIFICATION_ID,
                buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } catch (e: RuntimeException) {
            Log.w(TAG, "Could not enter the foreground", e)
            stopSelf()
        }
        // Only Dart knows the download: don't restart without it.
        return START_NOT_STICKY
    }

    /** Android 15+: data sync services get 6 hours a day. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        instance = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    private fun showNotification() {
        getSystemService(NotificationManager::class.java)
            ?.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun buildNotification(): Notification {
        val cancel = PendingIntent.getService(
            this,
            0,
            Intent(this, DownloadService::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        return Notification.Builder(this, CHANNEL_ID)
            // A system icon: R8 can't strip it from the release build.
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText("$percent%")
            .setProgress(100, percent, false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setContentIntent(open)
            .addAction(
                Notification.Action.Builder(
                    null,
                    cancelLabel,
                    cancel,
                ).build(),
            )
            .build()
    }
}

/**
 * Sends downloads over the watch's own Wi-Fi.
 *
 * Near the phone, a watch's default network is the phone's Bluetooth proxy,
 * which is slow for a whole book, and Wear OS turns Wi-Fi off soon after the
 * screen goes off. A Wi-Fi request keeps Wi-Fi up, and binding the process
 * to it routes new connections over it until [release].
 */
object DownloadNetwork {
    private const val TAG = "DownloadNetwork"
    private const val WAIT_MS = 5000L

    private val main = Handler(Looper.getMainLooper())
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var bound: Network? = null
    private var useDefault = false

    /**
     * Requests Wi-Fi and calls [done] on the main thread with true once the
     * process is bound to it, or false after a short wait without Wi-Fi.
     */
    fun acquire(context: Context, done: (Boolean) -> Unit) {
        val manager = context.applicationContext
            .getSystemService(ConnectivityManager::class.java)
        if (manager == null) {
            done(false)
            return
        }
        release(context)
        useDefault = false
        var answered = false
        // Wi-Fi that shows up after the wait isn't used: the download was
        // told it's on the default network, so it would have no fallback.
        var timedOut = false
        fun answer(onWifi: Boolean) {
            if (answered) return
            answered = true
            done(onWifi)
        }
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                main.post {
                    if (callback !== this) return@post
                    // A failed bind (Wi-Fi gone again) isn't answered: a
                    // later onAvailable may still bind, else the timeout
                    // answers false and drops the request.
                    if (!timedOut && !useDefault && manager.bindProcessToNetwork(network)) {
                        bound = network
                        answer(true)
                    }
                }
            }

            override fun onLost(network: Network) {
                main.post {
                    if (callback !== this || bound != network) return@post
                    manager.bindProcessToNetwork(null)
                    bound = null
                }
            }
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        try {
            manager.requestNetwork(request, cb)
            callback = cb
            main.postDelayed({
                if (!answered) {
                    timedOut = true
                    // Unused from now on: stop keeping Wi-Fi up and scanning.
                    dropRequest(manager, cb)
                }
                answer(false)
            }, WAIT_MS)
        } catch (e: RuntimeException) {
            Log.w(TAG, "Could not request Wi-Fi", e)
            answer(false)
        }
    }

    /**
     * Routes over the default network again, for a server that the watch's
     * Wi-Fi can't reach. Drops the Wi-Fi request only when the default
     * network isn't Wi-Fi: otherwise the request is what keeps Wi-Fi up
     * with the screen off, so it stays until [release].
     */
    fun useDefaultNetwork(context: Context) {
        useDefault = true
        val manager = context.applicationContext
            .getSystemService(ConnectivityManager::class.java) ?: return
        if (bound != null) {
            manager.bindProcessToNetwork(null)
            bound = null
        }
        val default = manager.activeNetwork ?: return
        val defaultIsWifi = manager.getNetworkCapabilities(default)
            ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ?: true
        if (!defaultIsWifi) callback?.let { dropRequest(manager, it) }
    }

    /** Unregisters [cb] if it is still the current request (not a newer one). */
    private fun dropRequest(manager: ConnectivityManager, cb: ConnectivityManager.NetworkCallback) {
        if (callback !== cb) return
        callback = null
        try {
            manager.unregisterNetworkCallback(cb)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Network callback was not registered", e)
        }
    }

    fun release(context: Context) {
        val manager = context.applicationContext
            .getSystemService(ConnectivityManager::class.java) ?: return
        if (bound != null) {
            manager.bindProcessToNetwork(null)
            bound = null
        }
        val cb = callback ?: return
        callback = null
        try {
            manager.unregisterNetworkCallback(cb)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Network callback was not registered", e)
        }
    }
}
