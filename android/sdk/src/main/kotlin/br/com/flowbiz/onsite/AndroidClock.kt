package br.com.flowbiz.onsite

import android.os.SystemClock

internal object AndroidClock : Clock {
    // elapsedRealtime, not uptimeMillis: deep sleep is inactivity and must count toward session expiry.
    override fun monotonicMillis(): Long = SystemClock.elapsedRealtime()
    override fun wallMillis(): Long = System.currentTimeMillis()
}
