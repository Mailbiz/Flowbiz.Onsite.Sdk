package br.com.flowbiz.onsite

import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Cancellable handle for a scheduled task. Cancelling twice is harmless. */
internal interface ScheduledHandle {
    fun cancel()
}

/**
 * The SDK's serial execution seam: queue I/O, HTTP, backoff retries and
 * heartbeat ticks all run on one **single-threaded** executor, so queue and
 * flush state are thread-confined without locking. Injected so tests drive
 * time and execution manually.
 */
internal interface TaskScheduler {
    fun execute(task: Runnable)

    fun schedule(delayMillis: Long, task: Runnable): ScheduledHandle

    /** First run one full interval after scheduling; fixed delay between runs. */
    fun scheduleRepeating(intervalMillis: Long, task: Runnable): ScheduledHandle
}

/** Never throws: a task rejected by a shut-down executor degrades to a no-op handle. */
internal class ExecutorTaskScheduler(
    private val executor: ScheduledExecutorService,
) : TaskScheduler {

    private class FutureHandle(private val future: ScheduledFuture<*>) : ScheduledHandle {
        override fun cancel() {
            try {
                future.cancel(false)
            } catch (_: Throwable) {
            }
        }
    }

    private object NoopHandle : ScheduledHandle {
        override fun cancel() {}
    }

    override fun execute(task: Runnable) {
        try {
            executor.execute(task)
        } catch (_: RejectedExecutionException) {
            SdkLog.debug("scheduler rejected task (shutting down)")
        }
    }

    override fun schedule(delayMillis: Long, task: Runnable): ScheduledHandle = try {
        FutureHandle(executor.schedule(task, delayMillis, TimeUnit.MILLISECONDS))
    } catch (_: RejectedExecutionException) {
        SdkLog.debug("scheduler rejected delayed task (shutting down)")
        NoopHandle
    }

    override fun scheduleRepeating(intervalMillis: Long, task: Runnable): ScheduledHandle = try {
        FutureHandle(
            executor.scheduleWithFixedDelay(task, intervalMillis, intervalMillis, TimeUnit.MILLISECONDS)
        )
    } catch (_: RejectedExecutionException) {
        SdkLog.debug("scheduler rejected repeating task (shutting down)")
        NoopHandle
    }
}
