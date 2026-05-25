package com.memekaruta.android

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import java.util.concurrent.CopyOnWriteArrayList

/**
 * ネットワーク接続状態を監視し、変化があった時にリスナーへ通知するヘルパー。
 *
 * WebSocket クライアントから「接続が落ちたっぽい」を即時に検知して、
 * 自動再接続のトリガーにする想定。Android のネットワーク状態 API は
 * OS バージョンによって挙動が違うので、ここでまとめて吸収する。
 */
class ConnectionMonitor(private val context: Context) {

    enum class Quality { ONLINE_WIFI, ONLINE_CELLULAR, ONLINE_OTHER, OFFLINE }

    interface Listener {
        fun onConnectionChanged(quality: Quality)
    }

    private val cm: ConnectivityManager by lazy {
        context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    private val listeners = CopyOnWriteArrayList<Listener>()
    private val handler = Handler(Looper.getMainLooper())

    @Volatile
    private var currentQuality: Quality = Quality.OFFLINE

    private var registered = false

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            updateQuality()
        }

        override fun onLost(network: Network) {
            updateQuality()
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            updateQuality()
        }
    }

    fun start() {
        if (registered) return
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        try {
            cm.registerNetworkCallback(request, callback)
            registered = true
            updateQuality()
        } catch (e: SecurityException) {
            AnalyticsLogger.shared().log("conn_monitor_register_failed", mapOf("error" to (e.message ?: "?")))
        }
    }

    fun stop() {
        if (!registered) return
        try {
            cm.unregisterNetworkCallback(callback)
        } catch (e: IllegalArgumentException) {
            // 既に解除済み
        }
        registered = false
    }

    fun addListener(listener: Listener) {
        listeners.add(listener)
        handler.post { listener.onConnectionChanged(currentQuality) }
    }

    fun removeListener(listener: Listener) {
        listeners.remove(listener)
    }

    fun current(): Quality = currentQuality

    fun isOnline(): Boolean = currentQuality != Quality.OFFLINE

    private fun updateQuality() {
        val newQuality = detectQuality()
        val changed = newQuality != currentQuality
        currentQuality = newQuality
        if (changed) {
            AnalyticsLogger.shared().log("connection_changed", mapOf("quality" to newQuality.name))
            handler.post {
                for (l in listeners) l.onConnectionChanged(newQuality)
            }
        }
    }

    private fun detectQuality(): Quality {
        val activeNetwork = cm.activeNetwork ?: return Quality.OFFLINE
        val capabilities = cm.getNetworkCapabilities(activeNetwork) ?: return Quality.OFFLINE
        if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
            return Quality.OFFLINE
        }
        if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) {
            return Quality.OFFLINE
        }
        return when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Quality.ONLINE_WIFI
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Quality.ONLINE_CELLULAR
            else -> Quality.ONLINE_OTHER
        }
    }

    companion object {
        @Volatile
        private var instance: ConnectionMonitor? = null

        fun shared(context: Context): ConnectionMonitor {
            return instance ?: synchronized(this) {
                instance ?: ConnectionMonitor(context.applicationContext).also { instance = it }
            }
        }
    }
}
