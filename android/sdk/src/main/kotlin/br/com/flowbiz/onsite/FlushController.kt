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

    enum class FlushReason { EVENT_TRACKED, APP_FOREGROUND, APP_BACKGROUND, NETWORK_RESTORED, EXPLICIT }

    private enum class Outcome { CONTINUE, STOP_AND_RETRY }

    private val lock = Any()
    private var draining = false
    private var drainAgain = false
    private var drainQueued = false
    private val waiters = mutableListOf<() -> Unit>()
    private var backoffMillis = INITIAL_BACKOFF_MS
    private var retryHandle: ScheduledHandle? = null

    /** [onDrained] runs once the drain this request joins is over: queue empty, a retry scheduled, or SDK disabled. */
    fun requestFlush(reason: FlushReason, onDrained: (() -> Unit)? = null) {
        try {
            SdkLog.debug("flush requested: $reason")
            // One waiting drain is enough: triggers that arrive while a send blocks would only repeat it.
            val alreadyQueued = synchronized(lock) {
                backoffMillis = INITIAL_BACKOFF_MS
                retryHandle?.cancel()
                retryHandle = null
                if (onDrained != null) waiters += onDrained
                drainQueued.also { drainQueued = true }
            }
            if (!alreadyQueued) scheduler.execute { drain() }
        } catch (t: Throwable) {
            SdkLog.debug("requestFlush failed: ${t.javaClass.simpleName}")
            // No drain is coming: nobody may wait on it, and the next request must queue one.
            notify(synchronized(lock) { drainQueued = false; takeWaiters() })
        }
    }

    private fun drain() {
        val waiting = synchronized(lock) {
            drainQueued = false
            // Re-entrant with an inline executor (a trigger mid-drain): coalesce into one follow-up pass.
            if (draining) {
                drainAgain = true
                return
            }
            draining = true
            takeWaiters()
        }
        try {
            if (!isActive()) SdkLog.debug("drain skipped: SDK disabled")
            // isActive again per batch: setEnabled(false) no longer waits for this thread.
            while (queue.size > 0 && isActive()) {
                val outcome = drainPrefix(batchSize)
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
            notify(waiting)
            if (again) scheduler.execute { drain() }
        }
    }

    private fun takeWaiters(): List<() -> Unit> = waiters.toList().also { waiters.clear() }

    private fun notify(waiting: List<() -> Unit>) {
        for (onDrained in waiting) {
            try {
                onDrained()
            } catch (t: Throwable) {
                SdkLog.debug("flush callback failed: ${t.javaClass.simpleName}")
            }
        }
    }

    private fun drainPrefix(count: Int): Outcome {
        val batch = queue.peek(count)
        val entries = batch.entries
        if (entries.isEmpty()) return Outcome.CONTINUE
        return when (sender.send(buildBody(entries))) {
            SendResult.SUCCESS -> {
                queue.remove(batch)
                Outcome.CONTINUE
            }

            SendResult.RETRIABLE_ERROR -> Outcome.STOP_AND_RETRY

            // The verdict covers the whole POST: bisect so only the poison entry is dropped.
            SendResult.PAYLOAD_TOO_LARGE, SendResult.PERMANENT_ERROR -> {
                if (entries.size == 1) {
                    SdkLog.debug("dropping poison event (rejected by collector)")
                    queue.remove(batch)
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
