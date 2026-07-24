package com.flowbiz.onsite

import org.json.JSONObject

/**
 * The SPEC §9 drain loop: batches the [EventQueue] through the [HttpSender]
 * in order, with 413 bisection, poison isolation, and exponential backoff.
 *
 * ## Drain semantics
 * - Batches of up to [MAX_BATCH_SIZE] (50) entries per request, queue order.
 * - `sent_at` is restamped on every entry at **each transmission attempt**
 *   (SPEC §4); `created_at` is never touched.
 * - [SendResult.SUCCESS] → dequeue exactly the batch, continue draining.
 * - [SendResult.PAYLOAD_TOO_LARGE] → split the batch in half, retry the
 *   halves recursively; a single entry still oversized is poison → dropped.
 * - [SendResult.PERMANENT_ERROR] → same bisection. SPEC §9's "drop it" is
 *   per-event, but a 4xx verdict applies to the whole POST — dropping the
 *   full batch would lose innocent events, so the batch is bisected exactly
 *   like a 413 until the poison entries are isolated and only those are
 *   dropped (a deliberate interpretation, flagged for review).
 * - [SendResult.RETRIABLE_ERROR] → stop draining (order preserved),
 *   schedule a retry with backoff.
 *
 * ## Backoff
 * Exponential 1 s → 60 s cap. **Any** [requestFlush] trigger (next track,
 * foreground, network restored, explicit flush — wired by the facade in
 * Slice 4) resets the backoff to 1 s, cancels a pending retry and attempts
 * immediately (SPEC §9). Scheduled retries themselves do not reset it.
 *
 * ## Concurrency
 * All drain work runs on the injected serial [TaskScheduler]; a guard flag
 * makes overlapping/re-entrant drain requests coalesce into one follow-up
 * pass, so flushes never run concurrently. [requestFlush] is callable from
 * any thread and never throws (SPEC §3).
 */
internal class FlushController(
    private val queue: EventQueue,
    private val sender: HttpSender,
    private val scheduler: TaskScheduler,
    private val clock: Clock,
    private val batchSize: Int = MAX_BATCH_SIZE,
    private val isActive: () -> Boolean = { true },
) {

    /** SPEC §9 retry triggers; carried for debug logging only. */
    enum class FlushReason { EVENT_TRACKED, APP_FOREGROUND, NETWORK_RESTORED, EXPLICIT }

    private enum class Outcome { CONTINUE, STOP_AND_RETRY }

    private val lock = Any()
    private var draining = false
    private var drainAgain = false
    private var backoffMillis = INITIAL_BACKOFF_MS
    private var retryHandle: ScheduledHandle? = null

    /**
     * Requests an immediate flush. Resets the backoff and cancels any
     * pending scheduled retry (SPEC §9: reset by any retry trigger).
     */
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
        // SPEC §12 gate: while the SDK is disabled no network happens — this
        // also covers a backoff retry scheduled *before* the disable (it
        // fires, hits the gate, and schedules nothing further).
        if (!isActive()) {
            SdkLog.debug("drain skipped: SDK disabled")
            return
        }
        synchronized(lock) {
            if (draining) {
                // Re-entrant request (e.g. a trigger firing mid-drain with an
                // inline executor): coalesce into one follow-up pass.
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
     * Builds the `{"data":[...]}` body, restamping `timings.sent_at` with
     * the current wall clock on every entry (SPEC §4: per attempt).
     * A defensively-unparseable entry is sent verbatim rather than dropped.
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
        /** SPEC §9: ≤ 50 events per request. */
        const val MAX_BATCH_SIZE = 50

        /** SPEC §9: exponential backoff, 1 s doubling to a 60 s cap. */
        const val INITIAL_BACKOFF_MS = 1_000L
        const val MAX_BACKOFF_MS = 60_000L
    }
}
