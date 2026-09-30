package br.com.flowbiz.onsite

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network

internal interface ReachabilityMonitor {
    fun start(onNetworkAvailable: Runnable)

    fun stop()
}

internal class AndroidReachability(context: Context) : ReachabilityMonitor {

    private val appContext = context.applicationContext
    private val lock = Any()
    private var callback: ConnectivityManager.NetworkCallback? = null

    override fun start(onNetworkAvailable: Runnable) {
        synchronized(lock) {
            if (callback != null) return
            try {
                val manager = appContext.getSystemService(Context.CONNECTIVITY_SERVICE)
                    as? ConnectivityManager ?: return
                val networkCallback = object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        try {
                            onNetworkAvailable.run()
                        } catch (_: Throwable) {
                        }
                    }
                }
                manager.registerDefaultNetworkCallback(networkCallback)
                callback = networkCallback
            } catch (t: Throwable) {
                SdkLog.debug("reachability unavailable: ${t.javaClass.simpleName}")
            }
        }
    }

    override fun stop() {
        synchronized(lock) {
            val registered = callback ?: return
            callback = null
            try {
                val manager = appContext.getSystemService(Context.CONNECTIVITY_SERVICE)
                    as? ConnectivityManager ?: return
                manager.unregisterNetworkCallback(registered)
            } catch (t: Throwable) {
                SdkLog.debug("reachability stop failed: ${t.javaClass.simpleName}")
            }
        }
    }
}
