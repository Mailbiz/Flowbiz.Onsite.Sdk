package com.flowbiz.onsite

/**
 * SPEC §8 heartbeat: while started (facade calls [start] on foreground,
 * [stop] on background — Slice 4), emits a `page.ping` envelope every
 * interval on the SDK's serial [TaskScheduler].
 *
 * Fire-and-forget by design: the ping goes **directly through the
 * [HttpSender], bypassing the queue** — any failure is dropped, never
 * retried, never persisted, so a flaky network cannot fill the durable
 * queue with heartbeats and evict real events (SPEC §8).
 *
 * [envelopeProvider] returns the serialized `page.ping` envelope entry
 * (see `EnvelopeBuilder.buildPing`) with fresh identity/timing values, or
 * null to skip a beat (e.g. SDK disabled). The first beat fires one full
 * interval after [start] (matching web `pagePingDelay` cadence). Interval
 * clamping (≥ 15 s) is config-side, Slice 4.
 *
 * Thread-safe; never throws (SPEC §3).
 */
internal class HeartbeatScheduler(
    private val scheduler: TaskScheduler,
    private val sender: HttpSender,
    private val envelopeProvider: () -> String?,
) {

    private val lock = Any()
    private var handle: ScheduledHandle? = null

    /** Starts (or restarts with a new interval) the repeating heartbeat. */
    fun start(intervalMillis: Long) {
        synchronized(lock) {
            handle?.cancel()
            handle = try {
                scheduler.scheduleRepeating(intervalMillis) { tick() }
            } catch (t: Throwable) {
                SdkLog.debug("heartbeat start failed: ${t.javaClass.simpleName}")
                null
            }
        }
    }

    /** Stops the heartbeat (app backgrounded). Safe when not started. */
    fun stop() {
        synchronized(lock) {
            handle?.cancel()
            handle = null
        }
    }

    private fun tick() {
        try {
            val entry = envelopeProvider() ?: return
            // Result deliberately ignored: success and failure are equal —
            // no retry, no queue write (SPEC §8).
            sender.send("{\"data\":[$entry]}")
        } catch (t: Throwable) {
            SdkLog.debug("heartbeat tick failed: ${t.javaClass.simpleName}")
        }
    }
}
