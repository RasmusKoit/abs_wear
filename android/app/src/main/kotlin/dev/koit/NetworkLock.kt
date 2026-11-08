package dev.koit.abs_wear

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log

/**
 * Keeps a fast network (Wi-Fi or cellular) up while a streamed book plays.
 *
 * Wear OS turns Wi-Fi off soon after the screen goes off and routes traffic
 * over the slow Bluetooth link to the phone, so streaming stalls once the
 * player's buffer runs out. An active network request keeps the radio on;
 * binding the process makes the player's connections use it.
 *
 * A singleton: playback continues after the activity is gone.
 */
object NetworkLock {
    private const val TAG = "NetworkLock"
    private var callback: ConnectivityManager.NetworkCallback? = null

    fun acquire(context: Context) {
        if (callback != null) return
        val manager = context.applicationContext
            .getSystemService(ConnectivityManager::class.java) ?: return
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                manager.bindProcessToNetwork(network)
            }

            override fun onLost(network: Network) {
                // Fall back to the default network (e.g. Bluetooth proxy).
                if (manager.boundNetworkForProcess == network) {
                    manager.bindProcessToNetwork(null)
                }
            }
        }
        try {
            manager.requestNetwork(request, cb)
            callback = cb
        } catch (e: RuntimeException) {
            Log.w(TAG, "Could not request a network", e)
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
        manager.bindProcessToNetwork(null)
    }
}
