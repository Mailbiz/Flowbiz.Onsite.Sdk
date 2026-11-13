package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class BackgroundFlushTest {

    @get:Rule
    val temp = TemporaryFolder()

    private class FakeBackgroundFlush : BackgroundFlush {
        val calls = mutableListOf<String>()
        var accepts = true
        override fun schedule(): Boolean {
            calls += "schedule"
            return accepts
        }
        override fun cancel() { calls += "cancel" }

        // What a previous process of the app left with the system.
        var pending = false
        override fun isPending() = pending
    }

    private val job = FakeBackgroundFlush()

    // In the foreground, as an app is before it can go to the background.
    private fun harness() = CoreHarness(temp.newFolder(), backgroundFlush = job).also { it.core.onForeground() }

    private fun CoreHarness.queueOneOffline() {
        sender.defaultResult = SendResult.RETRIABLE_ERROR
        core.track(Event.CartSetCoupon(cartId = "c-1", coupon = "last-before-leaving"))
        assertEquals(1, queue.size)
    }

    @Test
    fun backgroundingFlushesWhatIsQueued() {
        val h = harness()
        h.queueOneOffline()
        h.sender.defaultResult = SendResult.SUCCESS
        val sends = h.sender.bodies.size

        h.core.onBackground()

        assertEquals(sends + 1, h.sender.bodies.size)
        assertEquals(0, h.queue.size)
    }

    @Test
    fun aQueueStillFullAfterTheBackgroundFlushLeavesAJobForTheNetwork() {
        val h = harness()
        h.queueOneOffline()

        h.core.onBackground()

        assertEquals(listOf("schedule"), job.calls)
        assertEquals(1, h.queue.size)
    }

    @Test
    fun theJobIsCancelledOnceTheBackgroundFlushEmptiesTheQueue() {
        val h = harness()
        h.queueOneOffline()
        h.sender.defaultResult = SendResult.SUCCESS

        h.core.onBackground()

        assertEquals(listOf("schedule", "cancel"), job.calls)
    }

    @Test
    fun theJobIsCancelledOnTheSdkThreadWhereItIsScheduled() {
        val h = CoreHarness(temp.newFolder(), backgroundFlush = job, transportScheduler = FakeTaskScheduler())
        h.core.onForeground()
        h.queueOneOffline()
        h.sender.defaultResult = SendResult.SUCCESS

        h.scheduler.deferExecute = true
        h.core.onBackground()
        h.scheduler.runNextDeferred() // onBackground; the transport drains inline and empties the queue

        // Not from the transport thread: there it could cancel the job a later onBackground scheduled.
        assertEquals(0, h.queue.size)
        assertEquals(listOf("schedule"), job.calls)
        h.scheduler.runNextDeferred()
        assertEquals(listOf("schedule", "cancel"), job.calls)
    }

    @Test
    fun anEventTrackedOfflineAfterBackgroundingLeavesAJob() {
        val h = harness()
        h.core.onBackground() // nothing queued yet: no job
        assertEquals(emptyList<String>(), job.calls)

        h.queueOneOffline() // a CartSync in onStop after super.onStop(), or from a service

        assertEquals(listOf("schedule"), job.calls)
    }

    @Test
    fun anEventTrackedOfflineInTheForegroundLeavesNoJob() {
        val h = harness()
        h.queueOneOffline()
        assertEquals(emptyList<String>(), job.calls)
    }

    @Test
    fun theRetriesOfTheProcessKeepTheOneJob() {
        val h = harness()
        h.core.onBackground()
        h.queueOneOffline()

        h.scheduler.runLastScheduled() // the in-process retry fails again
        h.core.onBackground()

        // Scheduling again would replace the job, and with the network up it would start at once.
        assertEquals(listOf("schedule"), job.calls)
    }

    @Test
    fun aJobTheSystemRefusedIsScheduledAgainByTheNextRetry() {
        val h = harness()
        h.core.onBackground()
        job.accepts = false
        h.queueOneOffline()
        assertEquals(listOf("schedule"), job.calls)
        job.accepts = true

        h.scheduler.runLastScheduled() // the in-process retry fails again

        // A refused job is not held: counting it as one would leave the queue with no job at all.
        assertEquals(listOf("schedule", "schedule"), job.calls)
    }

    @Test
    fun aJobWhoseFlushFailsIsLeftForTheSystemToReschedule() {
        val h = CoreHarness(temp.newFolder(), backgroundFlush = job) // a process started for the job
        h.queue.append("{\"event\":\"cart.sync\"}")
        h.sender.defaultResult = SendResult.RETRIABLE_ERROR
        val reports = mutableListOf<Boolean>()

        h.core.flushFromJob { reports += it }

        assertEquals(listOf(false), reports) // jobFinished(reschedule = true)
        assertEquals(emptyList<String>(), job.calls)
    }

    @Test
    fun afterAJobEmptiedTheQueueALaterEventGetsANewOne() {
        val h = CoreHarness(temp.newFolder(), backgroundFlush = job)
        h.queue.append("{\"event\":\"cart.sync\"}")
        val reports = mutableListOf<Boolean>()

        h.core.flushFromJob { reports += it }
        assertEquals(listOf(true), reports) // the system drops the job
        h.queueOneOffline()

        assertEquals(listOf("cancel", "schedule"), job.calls)
    }

    @Test
    fun aJobThatEmptiedTheQueueIsCancelledInCaseTheSystemRescheduledIt() {
        val h = CoreHarness(temp.newFolder(), backgroundFlush = job)
        h.queue.append("{\"event\":\"cart.sync\"}")
        val reports = mutableListOf<Boolean>()

        h.core.flushFromJob { reports += it }

        // Stopped mid-run (onStopJob returns true), the job is pending again and its jobFinished is ignored.
        assertEquals(listOf(true), reports)
        assertEquals(listOf("cancel"), job.calls)
    }

    @Test
    fun theJobIsCancelledWhenTheAppComesBackAndEmptiesTheQueue() {
        val h = harness()
        h.queueOneOffline()
        h.core.onBackground()
        assertEquals(listOf("schedule"), job.calls)
        h.sender.defaultResult = SendResult.SUCCESS

        h.core.onForeground()

        assertEquals(0, h.queue.size)
        assertEquals(listOf("schedule", "cancel"), job.calls) // else it wakes the process for nothing
    }

    @Test
    fun aJobLeftByAPreviousProcessIsCancelledOnceTheQueueIsEmpty() {
        job.pending = true // scheduled by a process the system killed since
        val h = CoreHarness(temp.newFolder(), backgroundFlush = job)
        h.queue.append("{\"event\":\"cart.sync\"}")

        h.core.onForeground()

        assertEquals(0, h.queue.size)
        assertEquals(listOf("cancel"), job.calls) // else it later starts the process for nothing
    }

    @Test
    fun aJobLeftByAPreviousProcessIsNotReplacedByTheRetries() {
        job.pending = true
        val h = CoreHarness(temp.newFolder(), backgroundFlush = job)

        h.queueOneOffline() // not in the foreground: a process started by a push, say

        assertEquals(emptyList<String>(), job.calls)
    }

    @Test
    fun aJobLeftByAPreviousProcessIsCancelledByTheOptOut() {
        job.pending = true
        val h = CoreHarness(temp.newFolder(), backgroundFlush = job)

        h.core.setEnabled(false)

        assertEquals(listOf("cancel"), job.calls)
    }

    @Test
    fun anEmptyQueueSchedulesNothing() {
        val h = harness()
        h.core.track(Event.PageView("home"))
        assertEquals(0, h.queue.size)

        h.core.onBackground()

        assertEquals(emptyList<String>(), job.calls)
    }

    @Test
    fun whileDisabledBackgroundingTouchesNeitherTheNetworkNorTheJob() {
        val h = harness()
        h.queueOneOffline()
        h.core.setEnabled(false)
        val sends = h.sender.bodies.size

        h.core.onBackground()

        assertEquals(sends, h.sender.bodies.size)
        assertEquals(emptyList<String>(), job.calls)
    }

    @Test
    fun disablingCancelsTheJobItLeft() {
        val h = harness()
        h.queueOneOffline()
        h.core.onBackground()
        assertEquals(listOf("schedule"), job.calls)

        h.core.setEnabled(false)

        // After an opt-out the SDK must not wake the app, even for a job that would send nothing.
        assertEquals(listOf("schedule", "cancel"), job.calls)
    }

    @Test
    fun theJobFlushesThroughTheCoreAndReportsWhetherTheQueueIsEmpty() {
        val h = harness()
        h.queueOneOffline()
        val reports = mutableListOf<Boolean>()

        h.core.flush { reports += it }
        h.sender.defaultResult = SendResult.SUCCESS
        h.core.flush { reports += it }

        assertEquals(listOf(false, true), reports)
        assertEquals(0, h.queue.size)
    }

    @Test
    fun theJobFinishesAtOnceWhileDisabled() {
        val h = harness()
        h.queueOneOffline()
        h.core.setEnabled(false)
        val sends = h.sender.bodies.size
        val reports = mutableListOf<Boolean>()

        h.core.flush { reports += it }

        assertEquals(listOf(true), reports) // nothing the job may send: no retry
        assertEquals(sends, h.sender.bodies.size)
    }

    @Test
    fun withoutAnInitializedCoreTheJobHasNothingToDo() {
        var finished = false
        assertFalse(Flowbiz.backgroundFlush { finished = true })
        assertFalse(finished)
    }

    @Test
    fun aPendingJobOfTheSdksServiceIsTheSdks() {
        assertTrue(ownsFlushJob("br.com.flowbiz.onsite.FlowbizFlushJobService"))
    }

    @Test
    fun aPendingJobOfTheHostAppUnderTheSameIdIsNotTheSdks() {
        // Below Android 14 job ids are shared by the whole app: counted as held, the SDK would never
        // schedule its own job and would cancel the host's once the queue is empty.
        assertFalse(ownsFlushJob("com.example.host.SyncJobService"))
    }

    @Test
    fun noPendingJobIsNotTheSdks() {
        assertFalse(ownsFlushJob(null))
    }

    @Test
    fun aDrainReportsToEveryCallerThatWaitedOnIt() {
        val waiting = ArrayDeque<Runnable>()
        val scheduler = FakeTaskScheduler()
        val deferring = object : TaskScheduler by scheduler {
            override fun execute(task: Runnable) { waiting += task }
        }
        val queue = EventQueue(java.io.File(temp.newFolder(), "queue.jsonl"))
        val controller = FlushController(queue, FakeHttpSender(), deferring, FakeClock())
        var drained = 0
        repeat(2) { controller.requestFlush(FlushController.FlushReason.APP_BACKGROUND) { drained += 1 } }
        assertEquals(0, drained)
        waiting.removeFirst().run()
        assertEquals(2, drained)
        assertTrue(waiting.isEmpty())
    }
}
