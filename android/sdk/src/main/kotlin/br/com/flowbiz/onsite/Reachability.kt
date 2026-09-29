package br.com.flowbiz.onsite

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network

/** Network-restoration seam (a flush retry trigger); injectable so JVM tests use a fake. */
internal interface ReachabilityMonitor {
    /** Starts monitoring; [onNetworkAvailable] may fire on any thread. Idempotent. */
    fun start(onNetworkAvailable: Runnable)

    fun stop()
}

/**
 * Over [ConnectivityManager.registerDefaultNetworkCallback], which needs the
 * `ACCESS_NETWORK_STATE` permission merged from the SDK manifest.
 * `onAvailable` also fires once at registration when a network is already
 * up; the extra flush request is harmless. Never throws: a missing
 * permission or an exhausted callback budget degrades to "no reachability
 * trigger", and the other retry triggers still drain the queue.
 */
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
