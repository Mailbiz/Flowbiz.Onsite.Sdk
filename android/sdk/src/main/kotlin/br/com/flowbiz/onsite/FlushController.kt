package br.com.flowbiz.onsite

import org.json.JSONObject

/**
 * Drains the [EventQueue] through the [HttpSender] in queue order, in
 * batches of up to [MAX_BATCH_SIZE]. A 413 splits the batch in half,
 * recursively; a single still-rejected entry is poison and dropped. A 4xx
 * verdict applies to the whole POST, so it is bisected the same way: only
 * the poison entries are dropped, not the innocent ones batched with them.
 * A retriable error stops the drain (order preserved) and schedules a retry.
 *
 * Backoff doubles from 1 s to a 60 s cap; any [requestFlush] resets it and
 * drains now, scheduled retries do not. Drains run on the serial
 * [TaskScheduler], and re-entrant requests coalesce into one follow-up pass.
 */
internal class FlushController(
    private val queue: EventQueue,
    private val sender: HttpSender,
    private val scheduler: TaskScheduler,
    private val clock: Clock,
    private val batchSize: Int = MAX_BATCH_SIZE,
    private val isActive: () -> Boolean = { true },
) {

    /** Carried for debug logging only. */
    enum class FlushReason { EVENT_TRACKED, APP_FOREGROUND, NETWORK_RESTORED, EXPLICIT }

    private enum class Outcome { CONTINUE, STOP_AND_RETRY }

    private val lock = Any()
    private var draining = false
    private var drainAgain = false
    private var backoffMillis = INITIAL_BACKOFF_MS
    private var retryHandle: ScheduledHandle? = null

    /** Resets the backoff, cancels a pending retry and drains now. Any thread; never throws. */
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

    /** Runs on the serial scheduler thread only. */
    private fun drain() {
        // Also ends a backoff retry scheduled before a disable.
        if (!isActive()) {
            SdkLog.debug("drain skipped: SDK disabled")
            return
        }
        synchronized(lock) {
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

    /**
     * Sends the [count] oldest queued entries as one request, bisecting on
     * 413/permanent rejection. Recursion depth ≤ log2(batch) ≈ 6.
     */
    private fun drainPrefix(count: Int): Outcome {
        val entries = queue.peek(count)
        if (entries.isEmpty()) return Outcome.CONTINUE
        return when (sender.send(buildBody(entries))) {
            SendResult.SUCCESS -> {
                queue.removeOldest(entries.size)
                Outcome.CONTINUE
            }

            SendResult.RETRIABLE_ERROR -> Outcome.STOP_AND_RETRY

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

    /**
     * Restamps `timings.sent_at` on every attempt, so a retried event's
     * `created_at` → `sent_at` skew shows its real offline latency. An
     * unparseable entry is sent verbatim rather than dropped.
     */
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
        /** Keeps a request well under the collector's 3 MB cap. */
        const val MAX_BATCH_SIZE = 50

        const val INITIAL_BACKOFF_MS = 1_000L
        const val MAX_BACKOFF_MS = 60_000L
    }
}
