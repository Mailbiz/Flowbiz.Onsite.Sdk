package com.flowbiz.onsite

import android.os.SystemClock

/**
 * Real device clocks.
 *
 * Monotonic source is [SystemClock.elapsedRealtime]: monotonic since boot,
 * immune to wall-clock/NTP/timezone changes, and — crucially — **keeps
 * counting through deep sleep**. A device dozing in a drawer for 40 minutes
 * genuinely was inactive, so its session must rotate; `uptimeMillis` (which
 * pauses in deep sleep) would silently immortalize sessions. iOS mirrors
 * this with `mach_continuous_time()`, its sleep-inclusive analog (plain
 * `mach_absolute_time`/`CLOCK_UPTIME_RAW` stops during sleep there — see
 * `SystemClock.swift` for the asymmetry note).
 *
 * `elapsedRealtime` resets at reboot; the persisted wall-clock last-activity
 * fallback in [SessionManager] covers restarts and reboots alike.
 */
internal object AndroidClock : Clock {
    override fun monotonicMillis(): Long = SystemClock.elapsedRealtime()
    override fun wallMillis(): Long = System.currentTimeMillis()
}
