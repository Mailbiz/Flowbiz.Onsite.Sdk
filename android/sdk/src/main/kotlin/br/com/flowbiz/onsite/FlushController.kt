package br.com.flowbiz.onsite

import org.json.JSONObject

internal class FlushController(
    private val queue: EventQueue,
    private val sender: HttpSender,
    private val scheduler: TaskScheduler,
    private val clock: Clock,
    private val batchSize: Int = MAX_BATCH_SIZE,
    private val isActive: () -> Boolean = { true },
) {

    enum class FlushReason { EVENT_TRACKED, APP_FOREGROUND, NETWORK_RESTORED, EXPLICIT }

    private enum class Outcome { CONTINUE, STOP_AND_RETRY }

    private val lock = Any()
    private var draining = false
    private var drainAgain = false
    private var backoffMillis = INITIAL_BACKOFF_MS
    private var retryHandle: ScheduledHandle? = null

    fun requestFlush(reason: FlushReason) {
        try {
            synchronized(lock) {
                backoffMillis = INITIAL_BACKOFF_MS
                retryHandle?.cancel()
                retryHandle = null
            }
            SdkLog.debug("flush requested: $reason")
            scheduler.execute { drain() }
        } catch (t: Throwable) {
            SdkLog.debug("requestFlush failed: ${t.javaClass.simpleName}")
        }
    }

    private fun drain() {
        if (!isActive()) {
            SdkLog.debug("drain skipped: SDK disabled")
            return
        }
        synchronized(lock) {
            // Re-entrant with an inline executor (a trigger mid-drain): coalesce into one follow-up pass.
            if (draining) {
                drainAgain = true
                return
            }
            draining = true
        }
        try {
            while (queue.size > 0) {
                val outcome = drainPrefix(minOf(batchSize, queue.size))
                if (outcome == Outcome.STOP_AND_RETRY) {
                    scheduleRetry()
                    break
                }
            }
        } catch (t: Throwable) {
            SdkLog.debug("drain failed: ${t.javaClass.simpleName}")
        } finally {
            val again = synchronized(lock) {
                draining = false
                val a = drainAgain
                drainAgain = false
                a
            }
            if (again) scheduler.execute { drain() }
        }
    }

    private fun drainPrefix(count: Int): Outcome {
        val entries = queue.peek(count)
        if (entries.isEmpty()) return Outcome.CONTINUE
        return when (sender.send(buildBody(entries))) {
            SendResult.SUCCESS -> {
                queue.removeOldest(entries.size)
                Outcome.CONTINUE
            }

            SendResult.RETRIABLE_ERROR -> Outcome.STOP_AND_RETRY

            // The verdict covers the whole POST: bisect so only the poison entry is dropped.
            SendResult.PAYLOAD_TOO_LARGE, SendResult.PERMANENT_ERROR -> {
                if (entries.size == 1) {
                    SdkLog.debug("dropping poison event (rejected by collector)")
                    queue.removeOldest(1)
                    Outcome.CONTINUE
                } else {
                    val half = entries.size / 2
                    val first = drainPrefix(half)
                    if (first == Outcome.STOP_AND_RETRY) {
                        first
                    } else {
                        // The surviving second half is now the queue head.
                        drainPrefix(entries.size - half)
                    }
                }
            }
        }
    }

    private fun scheduleRetry() {
        synchronized(lock) {
            val delay = backoffMillis
            backoffMillis = minOf(backoffMillis * 2, MAX_BACKOFF_MS)
            retryHandle?.cancel()
            retryHandle = scheduler.schedule(delay) {
                synchronized(lock) { retryHandle = null }
                SdkLog.debug("flush retry after ${delay}ms backoff")
                drain()
            }
        }
    }

    // sent_at is restamped per attempt, so created_at → sent_at shows a retried event's real latency.
    private fun buildBody(entries: List<String>): String {
        val sentAt = EnvelopeBuilder.isoMillis(clock.wallMillis())
        return entries.joinToString(prefix = "{\"data\":[", separator = ",", postfix = "]}") { line ->
            try {
                val entry = JSONObject(line)
                val timings = entry.optJSONObject("timings")
                    ?: JSONObject().also { entry.put("timings", it) }
                timings.put("sent_at", sentAt)
                CanonicalJson.render(entry)
            } catch (t: Throwable) {
                SdkLog.debug("sent_at restamp failed, sending entry verbatim")
                line
            }
        }
    }

    companion object {
        // Keeps a request well under the collector's 3 MB cap.
        const val MAX_BATCH_SIZE = 50

        const val INITIAL_BACKOFF_MS = 1_000L
        const val MAX_BACKOFF_MS = 60_000L
    }
}
