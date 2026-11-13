package br.com.flowbiz.onsite

import java.util.concurrent.atomic.AtomicBoolean

// Ticks on the SDK scheduler, where the envelope is built; the blocking POST goes to the transport's.
internal class HeartbeatScheduler(
    private val scheduler: TaskScheduler,
    private val sender: HttpSender,
    private val transport: TaskScheduler = scheduler,
    private val isActive: () -> Boolean = { true },
    private val envelopeProvider: () -> String?,
) {

    private val lock = Any()
    private var handle: ScheduledHandle? = null
    private val sending = AtomicBoolean(false)

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
        // A ping still waiting behind a slow send is not joined by another.
        if (!sending.compareAndSet(false, true)) return
        try {
            val entry = envelopeProvider()
            if (entry == null) {
                sending.set(false)
                return
            }
            transport.execute {
                try {
                    // Built while enabled, but it may have waited here behind a slow drain: not after an opt-out.
                    // Straight to the sender, result ignored: queued offline pings would evict real events.
                    if (isActive()) sender.send("{\"data\":[$entry]}")
                } catch (t: Throwable) {
                    SdkLog.debug("heartbeat send failed: ${t.javaClass.simpleName}")
                } finally {
                    sending.set(false)
                }
            }
        } catch (t: Throwable) {
            sending.set(false)
            SdkLog.debug("heartbeat tick failed: ${t.javaClass.simpleName}")
        }
    }
}
