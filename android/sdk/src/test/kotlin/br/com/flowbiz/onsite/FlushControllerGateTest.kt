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
}
