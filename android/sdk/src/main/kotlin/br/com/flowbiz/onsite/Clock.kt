package br.com.flowbiz.onsite

/**
 * Time sources for session management (SPEC §6), injected so tests control
 * both clocks independently.
 *
 * - [monotonicMillis] drives the 30-min inactivity window **in-process**:
 *   arbitrary epoch, never affected by user clock changes / NTP / timezone
 *   travel. Resets across process restarts.
 * - [wallMillis] (epoch millis) feeds the envelope `timings` and the
 *   persisted last-activity restart fallback — never in-process expiry.
 */
internal interface Clock {
    fun monotonicMillis(): Long
    fun wallMillis(): Long
}
