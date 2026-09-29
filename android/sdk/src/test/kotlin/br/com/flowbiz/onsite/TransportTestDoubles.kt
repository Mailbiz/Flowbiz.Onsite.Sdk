package br.com.flowbiz.onsite

/**
 * `execute` runs inline (the test *is* the serial thread); delayed and
 * repeating tasks wait for the test to fire them.
 */
internal class FakeTaskScheduler : TaskScheduler {

    class FakeHandle(
        val delayMillis: Long,
        val task: Runnable,
        val repeating: Boolean,
    ) : ScheduledHandle {
        var cancelled = false
        override fun cancel() {
            cancelled = true
        }
    }

    val scheduled = mutableListOf<FakeHandle>()

    /** Every `schedule()` delay in call order, including later-cancelled ones. */
    val allScheduleDelays: List<Long>
        get() = scheduled.filter { !it.repeating }.map { it.delayMillis }

    override fun execute(task: Runnable) = task.run()

    override fun schedule(delayMillis: Long, task: Runnable): ScheduledHandle =
        FakeHandle(delayMillis, task, repeating = false).also { scheduled += it }

    override fun scheduleRepeating(intervalMillis: Long, task: Runnable): ScheduledHandle =
        FakeHandle(intervalMillis, task, repeating = true).also { scheduled += it }

    /** Fires the most recently scheduled, still-pending one-shot task. */
    fun runLastScheduled() {
        scheduled.last { !it.repeating && !it.cancelled }.task.run()
    }

    fun activeRepeating(): FakeHandle? = scheduled.lastOrNull { it.repeating && !it.cancelled }

    fun tickRepeating(times: Int = 1) {
        val handle = activeRepeating() ?: error("no active repeating task")
        repeat(times) { handle.task.run() }
    }
}

/** Scripted [HttpSender]; [maxDepth] above 1 means a send ran inside another. */
internal class FakeHttpSender : HttpSender {

    val bodies = mutableListOf<String>()
    val results = ArrayDeque<SendResult>()
    var defaultResult = SendResult.SUCCESS
    var resultFor: ((String) -> SendResult)? = null
    var onSend: ((String) -> Unit)? = null

    private var depth = 0
    var maxDepth = 0
        private set

    override fun send(body: String): SendResult {
        depth += 1
        maxDepth = maxOf(maxDepth, depth)
        try {
            bodies += body
            onSend?.invoke(body)
            resultFor?.let { return it(body) }
            return results.removeFirstOrNull() ?: defaultResult
        } finally {
            depth -= 1
        }
    }
}
