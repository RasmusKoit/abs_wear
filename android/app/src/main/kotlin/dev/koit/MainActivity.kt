package dev.koit.abs_wear

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.MotionEvent
import androidx.wear.ambient.AmbientLifecycleObserver
import com.ryanheise.audioservice.AudioServiceActivity
import com.samsung.wearable_rotary.WearableRotaryPlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Extends [AudioServiceActivity] (required by just_audio_background) so that
 * this activity can be the launcher activity and still forward rotary input.
 */
class MainActivity : AudioServiceActivity() {

    private var ambientChannel: MethodChannel? = null
    private lateinit var ambientObserver: AmbientLifecycleObserver
    private var burnInProtection = false

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
    }

    /**
     * Hooks rotary input (crown / bezel) into the "WearableRotaryPlugin" class.
     */
    override fun onGenericMotionEvent(event: MotionEvent?): Boolean {
        return when {
            WearableRotaryPlugin.onGenericMotionEvent(event) -> true
            else -> super.onGenericMotionEvent(event)
        }
    }

    /**
     * Makes the app assume the rounded canvas appearance on rounded screens.
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        intent.putExtra("background_mode", "transparent")
        super.onCreate(savedInstanceState)
        ambientObserver = AmbientLifecycleObserver(this, ambientCallback)
        lifecycle.addObserver(ambientObserver)
        // Media notifications are exempt from this permission, but some
        // watches hide app notifications without it.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }
}
