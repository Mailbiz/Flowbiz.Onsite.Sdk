package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class FlushControllerGateTest {

    @get:Rule
    val temp = TemporaryFolder()

    private val sender = FakeHttpSender()
    private val scheduler = FakeTaskScheduler()
    private val clock = FakeClock()
    private var active = true
    private lateinit var queue: EventQueue

    private fun controller(): FlushController {
        queue = EventQueue(File(temp.newFolder(), "queue.jsonl"))
        return FlushController(queue, sender, scheduler, clock, isActive = { active })
    }

    private fun entry(n: Int) = """{"event":"e$n","hash":"h$n"}"""

    @Test
    fun gateBlocksDirectRequestsScheduledRetriesAndSchedulesNothingFurther() {
        val controller = controller()
        queue.append(entry(1))
        sender.results.addLast(SendResult.RETRIABLE_ERROR)
        controller.requestFlush(FlushController.FlushReason.EVENT_TRACKED)
        assertEquals(1, sender.bodies.size)

        active = false
        val scheduledBefore = scheduler.scheduled.size
        scheduler.runLastScheduled()
        assertEquals(1, sender.bodies.size)
        assertEquals(scheduledBefore, scheduler.scheduled.size)

        controller.requestFlush(FlushController.FlushReason.EXPLICIT)
        assertEquals(1, sender.bodies.size)
        assertEquals(1, queue.size)

        active = true
        controller.requestFlush(FlushController.FlushReason.EXPLICIT)
        assertEquals(2, sender.bodies.size)
        assertEquals(0, queue.size)
    }

    @Test
    fun disablingMidDrainStopsBeforeTheNextBatch() {
        queue = EventQueue(File(temp.newFolder(), "queue.jsonl"))
        val controller = FlushController(queue, sender, scheduler, clock, batchSize = 2, isActive = { active })
        (1..5).forEach { queue.append(entry(it)) }
        sender.onSend = { active = false } // setEnabled(false) lands while the first POST is out
        controller.requestFlush(FlushController.FlushReason.EVENT_TRACKED)

        assertEquals(1, sender.bodies.size)
        assertEquals(3, queue.size)
        assertEquals(emptyList<Long>(), scheduler.allScheduleDelays)
    }

    @Test
    fun triggersThatArriveWhileADrainWaitsShareIt() {
        val waiting = ArrayDeque<Runnable>()
        val deferring = object : TaskScheduler by scheduler {
            override fun execute(task: Runnable) { waiting += task }
        }
        queue = EventQueue(File(temp.newFolder(), "queue.jsonl"))
        val controller = FlushController(queue, sender, deferring, clock)
        queue.append(entry(1))
        repeat(3) { controller.requestFlush(FlushController.FlushReason.EVENT_TRACKED) }
        assertEquals(1, waiting.size)

        waiting.removeFirst().run()
        assertEquals(1, sender.bodies.size)
        queue.append(entry(2))
        controller.requestFlush(FlushController.FlushReason.EVENT_TRACKED)
        assertEquals(1, waiting.size)
        waiting.removeFirst().run()
        assertEquals(0, queue.size)
    }
}
