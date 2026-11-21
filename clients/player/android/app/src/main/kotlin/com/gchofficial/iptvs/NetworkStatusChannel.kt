package com.gchofficial.iptvs

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

internal class NetworkStatusChannel(context: Context, messenger: BinaryMessenger) :
    EventChannel.StreamHandler {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val channel = EventChannel(messenger, "iptvs/network_status")
    private var callback: ConnectivityManager.NetworkCallback? = null

    init {
        channel.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val listener = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                events.success(status(capabilities))
            }

            override fun onLost(network: Network) {
                events.success("offline")
            }
        }
        try {
            connectivity.registerDefaultNetworkCallback(listener, Handler(Looper.getMainLooper()))
            callback = listener
            events.success(status(connectivity.activeNetwork?.let(connectivity::getNetworkCapabilities)))
        } catch (_: SecurityException) {
            onCancel(null)
            events.error("unavailable", "Network status unavailable", null)
        }
    }

    override fun onCancel(arguments: Any?) {
        callback?.let(connectivity::unregisterNetworkCallback)
        callback = null
    }

    fun dispose() {
        onCancel(null)
        channel.setStreamHandler(null)
    }

    private fun status(capabilities: NetworkCapabilities?): String = when {
        capabilities == null || !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) -> "offline"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
        else -> "online"
    }
}
