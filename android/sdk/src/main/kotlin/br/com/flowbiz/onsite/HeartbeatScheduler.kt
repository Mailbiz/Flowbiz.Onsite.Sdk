package br.com.flowbiz.onsite

/**
 * Emits a `page.ping` every interval while started. Fire-and-forget: the
 * ping goes **directly through the [HttpSender], bypassing the queue**, so
 * a flaky network cannot fill the durable queue with heartbeats and evict
 * real events. [envelopeProvider] returns null to skip a beat (SDK
 * disabled). The first beat fires one full interval after [start], like the
 * web `pagePingDelay` cadence. Thread-safe; never throws.
 */
internal class HeartbeatScheduler(
    private val scheduler: TaskScheduler,
    private val sender: HttpSender,
    private val envelopeProvider: () -> String?,
) {

    private val lock = Any()
    private var handle: ScheduledHandle? = null

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
            // no retry, no queue write.
            sender.send("{\"data\":[$entry]}")
        } catch (t: Throwable) {
            SdkLog.debug("heartbeat tick failed: ${t.javaClass.simpleName}")
        }
    }
}
