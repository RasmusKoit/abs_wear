package dev.koit.abs_wear

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Channel `audio_output`: Bluetooth audio outputs (no permission needed) and the Bluetooth picker. */
object AudioOutput {
    // BLE types are API 31+/33+; older watches never report them.
    @SuppressLint("InlinedApi")
    private val headphoneTypes = setOf(
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,
        AudioDeviceInfo.TYPE_BLE_BROADCAST,
        AudioDeviceInfo.TYPE_HEARING_AID,
    )

    private var callback: AudioDeviceCallback? = null

    private fun audioManager(context: Context) =
        context.getSystemService(AudioManager::class.java)

    private fun hasHeadphones(context: Context): Boolean {
        val manager = audioManager(context) ?: return true
        return manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .any { it.type in headphoneTypes }
    }

    fun register(engine: FlutterEngine, context: Context) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "audio_output")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasHeadphones" -> result.success(hasHeadphones(context))
                "openBluetoothSettings" -> result.success(openBluetoothSettings(context))
                "watch" -> {
                    unwatch(context)
                    val manager = audioManager(context)
                    val cb = object : AudioDeviceCallback() {
                        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) =
                            channel.invokeMethod("changed", hasHeadphones(context))

                        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) =
                            channel.invokeMethod("changed", hasHeadphones(context))
                    }
                    manager?.registerAudioDeviceCallback(cb, Handler(Looper.getMainLooper()))
                    callback = cb
                    result.success(null)
                }
                "unwatch" -> {
                    unwatch(context)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun unwatch(context: Context) {
        callback?.let { audioManager(context)?.unregisterAudioDeviceCallback(it) }
        callback = null
    }

    // The Wear OS audio docs' picker: connect only, close once connected.
    private fun openBluetoothSettings(context: Context): Boolean {
        val actions = listOf(
            Settings.ACTION_BLUETOOTH_SETTINGS,
            "com.google.android.clockwork.settings.BLUETOOTH",
        )
        for (action in actions) {
            val intent = Intent(action)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                .putExtra("EXTRA_CONNECTION_ONLY", true)
                .putExtra("EXTRA_CLOSE_ON_CONNECT", true)
                .putExtra("android.bluetooth.devicepicker.extra.FILTER_TYPE", 1)
            try {
                context.startActivity(intent)
                return true
            } catch (e: ActivityNotFoundException) {
                continue
            } catch (e: SecurityException) {
                continue
            }
        }
        return false
    }
}
