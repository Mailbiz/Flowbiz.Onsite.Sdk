package br.com.flowbiz.onsite

import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

internal interface ScheduledHandle {
    fun cancel()
}

// Must be serial: queue and flush state rely on thread confinement instead of locks.
internal interface TaskScheduler {
    fun execute(task: Runnable)

    fun schedule(delayMillis: Long, task: Runnable): ScheduledHandle

    // First fires one full interval after scheduling, like the web pagePingDelay.
    fun scheduleRepeating(intervalMillis: Long, task: Runnable): ScheduledHandle
}

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
