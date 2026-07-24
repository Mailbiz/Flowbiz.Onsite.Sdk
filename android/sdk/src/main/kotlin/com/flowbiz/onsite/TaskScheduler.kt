package com.flowbiz.onsite

import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Cancellable handle for a scheduled task. Cancelling twice is harmless. */
internal interface ScheduledHandle {
    fun cancel()
}

/**
 * The SDK's serial execution seam (SPEC §1: single background
 * `ExecutorService`). Everything the transport layer does — queue I/O,
 * HTTP, backoff retries, heartbeat ticks — runs through one implementation
 * of this interface backed by a **single-threaded** scheduled executor, so
 * queue and flush state are thread-confined without locking. Injected so
 * tests drive time and execution manually.
 */
internal interface TaskScheduler {
    /** Runs [task] on the serial thread as soon as possible. */
    fun execute(task: Runnable)

    /** Runs [task] on the serial thread after [delayMillis]. */
    fun schedule(delayMillis: Long, task: Runnable): ScheduledHandle

    /**
     * Runs [task] on the serial thread every [intervalMillis], first fire
     * one full interval after scheduling (fixed delay between runs).
     */
    fun scheduleRepeating(intervalMillis: Long, task: Runnable): ScheduledHandle
}

/**
 * Production [TaskScheduler] over a single-threaded
 * [ScheduledExecutorService] (Slice 4 owns its creation/lifecycle).
 * Never throws: a rejected task (executor shut down) degrades to a no-op
 * handle (SPEC §3).
 */
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
