package br.com.flowbiz.onsite

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
            // Straight to the sender, result ignored: queued offline pings would evict real events.
            sender.send("{\"data\":[$entry]}")
        } catch (t: Throwable) {
            SdkLog.debug("heartbeat tick failed: ${t.javaClass.simpleName}")
        }
    }
}
