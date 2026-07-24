package com.flowbiz.onsite

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network

/**
 * Network-restoration seam (SPEC §9 retry trigger). Implementations invoke
 * the callback when connectivity (re)appears; the facade wires it to
 * `FlushController.requestFlush(NETWORK_RESTORED)` in Slice 4. Injectable
 * so JVM tests use a fake.
 */
internal interface ReachabilityMonitor {
    /** Starts monitoring; [onNetworkAvailable] may fire on any thread. Idempotent. */
    fun start(onNetworkAvailable: Runnable)

    /** Stops monitoring. Safe to call when not started. */
    fun stop()
}

/**
 * Production monitor over
 * [ConnectivityManager.registerDefaultNetworkCallback] (SPEC §1, available
 * since API 24 — under our API 26 floor). Requires the normal-level
 * `ACCESS_NETWORK_STATE` permission, declared in the SDK manifest and
 * merged into consumers.
 *
 * `onAvailable` also fires once at registration when a network is already
 * up; the resulting extra flush request is harmless (an empty queue drain
 * is a no-op). Never throws: a missing permission or an exhausted callback
 * budget logs and degrades to "no reachability trigger" (SPEC §3) — the
 * other retry triggers still drain the queue.
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
