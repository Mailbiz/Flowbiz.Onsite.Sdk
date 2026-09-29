package br.com.flowbiz.onsite

import android.os.SystemClock

/**
 * Monotonic source is [SystemClock.elapsedRealtime], which **keeps counting
 * through deep sleep**: a device dozing in a drawer for 40 minutes genuinely
 * was inactive, so its session must rotate, while `uptimeMillis` (paused in
 * deep sleep) would silently immortalize sessions. iOS mirrors this with
 * `mach_continuous_time()`. It resets at reboot; the persisted wall-clock
 * fallback in [SessionManager] covers restarts and reboots alike.
 */
internal object AndroidClock : Clock {
    override fun monotonicMillis(): Long = SystemClock.elapsedRealtime()
    override fun wallMillis(): Long = System.currentTimeMillis()
}
