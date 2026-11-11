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
        override fun schedule() { calls += "schedule" }
        override fun cancel() { calls += "cancel" }
    }

    private val job = FakeBackgroundFlush()

    private fun harness() = CoreHarness(temp.newFolder(), backgroundFlush = job)

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
