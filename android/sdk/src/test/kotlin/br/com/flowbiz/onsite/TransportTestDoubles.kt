package br.com.flowbiz.onsite

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

    val allScheduleDelays: List<Long>
        get() = scheduled.filter { !it.repeating }.map { it.delayMillis }

    override fun execute(task: Runnable) = task.run()

    override fun schedule(delayMillis: Long, task: Runnable): ScheduledHandle =
        FakeHandle(delayMillis, task, repeating = false).also { scheduled += it }

    override fun scheduleRepeating(intervalMillis: Long, task: Runnable): ScheduledHandle =
        FakeHandle(intervalMillis, task, repeating = true).also { scheduled += it }

    fun runLastScheduled() {
        scheduled.last { !it.repeating && !it.cancelled }.task.run()
    }

    fun activeRepeating(): FakeHandle? = scheduled.lastOrNull { it.repeating && !it.cancelled }

    fun tickRepeating(times: Int = 1) {
        val handle = activeRepeating() ?: error("no active repeating task")
        repeat(times) { handle.task.run() }
    }
}

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
