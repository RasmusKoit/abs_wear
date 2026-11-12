package dev.koit.abs_wear

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.InputDevice
import android.view.MotionEvent
import android.widget.Toast
import androidx.wear.ambient.AmbientLifecycleObserver
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * Extends [AudioServiceActivity] (required by just_audio_background) so that
 * this activity can be the launcher activity and still handle rotary input.
 */
class MainActivity : AudioServiceActivity() {

    private var ambientChannel: MethodChannel? = null
    private lateinit var ambientObserver: AmbientLifecycleObserver
    private var burnInProtection = false

    /**
     * True while this activity's permission dialog is up, so a second
     * download can't stack another request. Per activity, not in the
     * companion: the result comes back to this activity (or the one that
     * replaced it, which starts at false), and a stale true can't outlive
     * it to block the next activity from asking.
     */
    private var askingNotifications = false

    /**
     * Reports ambient (always-on, low power) mode to Dart, where
     * AmbientModeListener switches the UI to a dim, static variant.
     */
    private val ambientCallback = object : AmbientLifecycleObserver.AmbientLifecycleCallback {
        override fun onEnterAmbient(ambientDetails: AmbientLifecycleObserver.AmbientDetails) {
            burnInProtection = ambientDetails.burnInProtectionRequired
            enterAmbient()
        }

        override fun onUpdateAmbient() {
            ambientChannel?.invokeMethod("onUpdateAmbient", null)
        }

        override fun onExitAmbient() {
            ambientChannel?.invokeMethod("onExitAmbient", null)
        }
    }

    private fun enterAmbient() {
        ambientChannel?.invokeMethod(
            "onEnterAmbient",
            mapOf("burnInProtection" to burnInProtection),
        )
    }

    /**
     * The Flutter engine outlives this activity, so tell it the current state
     * when coming back (a stale "ambient" would leave the UI dimmed).
     */
    override fun onResume() {
        super.onResume()
        if (ambientObserver.isAmbient) enterAmbient()
        else ambientChannel?.invokeMethod("onExitAmbient", null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ambientChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ambient_mode")
        val context = applicationContext
        // Crown turns for Dart's crownTurns stream: true when clockwise.
        // Registered once per engine: audio_service's cached engine outlives
        // this activity, and Dart keeps its subscription, so a handler set by
        // a later activity would never see onListen.
        if (crownEngine?.get() !== flutterEngine) {
            crownEngine = WeakReference(flutterEngine)
            crownSink = null
            EventChannel(flutterEngine.dartExecutor.binaryMessenger, "crown")
                .setStreamHandler(object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                        crownSink = events
                    }

                    override fun onCancel(arguments: Any?) {
                        crownSink = null
                    }
                })
            // A download dies with its Dart isolate, and nothing else would
            // stop the service, wake lock and Wi-Fi it holds.
            flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() = releaseDownload(context)

                override fun onEngineWillDestroy() {
                    releaseDownload(context)
                    DownloadService.onCancel = null
                }
            })
        }
        // Plain system toasts; a new one replaces the one still showing.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "toast")
            .setMethodCallHandler { call, result ->
                if (call.method != "show") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val length = if (call.argument<Boolean>("long") == true) {
                    Toast.LENGTH_LONG
                } else {
                    Toast.LENGTH_SHORT
                }
                toast?.cancel()
                toast = Toast.makeText(context, call.argument<String>("message") ?: "", length)
                    .also { it.show() }
                result.success(null)
            }
        // audio_service names its channel only when it first creates it.
        // Registering the same id again renames it (e.g. after a language
        // change) and keeps what the user set. Same importance and badge as
        // audio_service, for when this runs before it creates the channel.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "notification_channel")
            .setMethodCallHandler { call, result ->
                val id = call.argument<String>("id")
                val name = call.argument<String>("name")
                if (call.method != "nameAudio" || id == null || name.isNullOrEmpty()) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                context.getSystemService(NotificationManager::class.java)?.createNotificationChannel(
                    NotificationChannel(id, name, NotificationManager.IMPORTANCE_LOW).apply {
                        setShowBadge(false)
                    },
                )
                result.success(null)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "network_lock")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> result.success(NetworkLock.acquire(context))
                    "release" -> {
                        NetworkLock.release(context)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // "Continue on phone" sign-in through the Wear OS companion.
        RemoteAuth.register(flutterEngine, context)
        ContinueTile.register(flutterEngine, context)
        currentActivity = WeakReference(this)
        val downloads = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "download_keep_alive")
        DownloadService.onCancel = { downloads.invokeMethod("cancel", null) }
        downloads.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    DownloadService.start(
                        context,
                        call.argument<String>("title") ?: "",
                        call.argument<String>("cancel") ?: "",
                        call.argument<String>("channel") ?: "",
                    )
                    currentActivity?.get()?.askForNotifications()
                    DownloadNetwork.acquire(context) { onWifi -> result.success(onWifi) }
                }
                "progress" -> {
                    DownloadService.progress(call.argument<Int>("percent") ?: 0)
                    result.success(null)
                }
                "useDefaultNetwork" -> {
                    DownloadNetwork.useDefaultNetwork(context)
                    result.success(null)
                }
                "stop" -> {
                    releaseDownload(context)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * On API 33+ the download notification (progress and Cancel) stays hidden
     * without POST_NOTIFICATIONS; the media notification is exempt, so the
     * first download is when it starts to matter. Asked until answered once
     * per install, and not awaited: the download goes ahead either way.
     */
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            isFinishing || isDestroyed || askingNotifications ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val prefs = getSharedPreferences("permissions", MODE_PRIVATE)
        if (prefs.getBoolean(ASKED_NOTIFICATIONS, false)) return
        askingNotifications = true
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    /**
     * Only an answer counts as asked, so a dialog closed without one (back,
     * swipe, screen timeout) is shown again at the next download. Such a
     * close reports a denial too (or nothing, if interrupted); a real "Don't
     * allow" is the one denial after which the system offers a rationale.
     * super passes results on to Flutter's plugins.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_NOTIFICATIONS) return
        askingNotifications = false
        if (grantResults.isEmpty()) return
        if (grantResults[0] == PackageManager.PERMISSION_GRANTED ||
            shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)
        ) {
            getSharedPreferences("permissions", MODE_PRIVATE).edit()
                .putBoolean(ASKED_NOTIFICATIONS, true).apply()
        }
    }

    /**
     * Sends rotary input (crown / bezel) to Dart. A negative scroll axis is a
     * clockwise turn.
     */
    override fun onGenericMotionEvent(event: MotionEvent?): Boolean {
        if (event == null ||
            event.action != MotionEvent.ACTION_SCROLL ||
            !event.isFromSource(InputDevice.SOURCE_ROTARY_ENCODER)
        ) {
            return super.onGenericMotionEvent(event)
        }
        val delta = event.getAxisValue(MotionEvent.AXIS_SCROLL)
        if (delta != 0f) crownSink?.success(delta < 0)
        return true
    }

    /**
     * State shared with the long-lived engine's channel handlers, kept off
     * the activity so they never hold a destroyed one.
     */
    companion object {
        private const val REQUEST_NOTIFICATIONS = 1
        private const val ASKED_NOTIFICATIONS = "asked_notifications"
        private var currentActivity: WeakReference<MainActivity>? = null
        private var crownEngine: WeakReference<FlutterEngine>? = null
        private var crownSink: EventChannel.EventSink? = null
        private var toast: Toast? = null

        private fun releaseDownload(context: Context) {
            DownloadNetwork.release(context)
            DownloadService.stop(context)
        }
    }

    /**
     * Flutter draws into an opaque SurfaceView (the default). A transparent
     * background would force a TextureView, which composites every frame
     * once more and costs battery.
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ambientObserver = AmbientLifecycleObserver(this, ambientCallback)
        lifecycle.addObserver(ambientObserver)
        ContinueTile.onLaunch(intent, savedInstanceState == null)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        ContinueTile.onLaunch(intent, true)
    }
}
