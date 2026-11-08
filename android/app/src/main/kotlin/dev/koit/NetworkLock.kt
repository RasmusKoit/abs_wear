package dev.koit.abs_wear

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log

/**
 * Keeps the watch's Wi-Fi up while a streamed book plays.
 *
 * Wear OS turns Wi-Fi off soon after the screen goes off; without a phone
 * nearby that leaves no network, and streaming stops once the player's
 * buffer runs out. An active request keeps Wi-Fi connected. The process is
 * not bound to it: the system keeps routing over its default network (for
 * example the phone's Bluetooth proxy, which may reach servers on the
 * phone's VPN or LAN that the watch's own Wi-Fi can't).
 *
 * A singleton: playback continues after the activity is gone.
 */
object NetworkLock {
    private const val TAG = "NetworkLock"
    private var callback: ConnectivityManager.NetworkCallback? = null

    /** Returns false if the request could not be made. */
    fun acquire(context: Context): Boolean {
        if (callback != null) return true
        val manager = context.applicationContext
            .getSystemService(ConnectivityManager::class.java) ?: return false
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {}
        return try {
            manager.requestNetwork(request, cb)
            callback = cb
            true
        } catch (e: RuntimeException) {
            Log.w(TAG, "Could not request a network", e)
            false
        }
    }

    fun release(context: Context) {
        val cb = callback ?: return
        callback = null
        val manager = context.applicationContext
            .getSystemService(ConnectivityManager::class.java) ?: return
        try {
            manager.unregisterNetworkCallback(cb)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Network callback was not registered", e)
        }
    }
}
