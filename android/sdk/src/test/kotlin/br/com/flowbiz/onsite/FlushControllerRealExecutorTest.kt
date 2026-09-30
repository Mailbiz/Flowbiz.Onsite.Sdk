package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class FlushControllerRealExecutorTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun entry(n: Int) = """{"event":"e$n","hash":"h$n"}"""

    @Test(timeout = 15_000)
    fun drainsRetriesAndSettlesOnARealSingleThreadExecutor() {
        val executor = Executors.newSingleThreadScheduledExecutor()
        try {
            val scheduler = ExecutorTaskScheduler(executor)
            val sendsSeen = CountDownLatch(2)
            val queue = executor.submit<EventQueue> {
                EventQueue(File(temp.newFolder(), "queue.jsonl")).also {
                    it.append(entry(1))
                    it.append(entry(2))
                }
            }.get()
            val sender = FakeHttpSender()
            executor.submit {
                sender.results.addLast(SendResult.RETRIABLE_ERROR)
                sender.onSend = { sendsSeen.countDown() }
            }.get()

            val controller = FlushController(queue, sender, scheduler, FakeClock())
            controller.requestFlush(FlushController.FlushReason.EVENT_TRACKED)

            assertTrue(sendsSeen.await(10, TimeUnit.SECONDS))

            // Read on the executor: the drain can still be finishing when the latch opens.
            val (size, bodies) = executor.submit<Pair<Int, List<String>>> {
                queue.size to sender.bodies.toList()
            }.get()
            assertEquals(0, size)
            assertEquals(2, bodies.size)
            assertTrue(bodies.all { it.contains(""""hash":"h1"""") && it.contains(""""hash":"h2"""") })
        } finally {
            executor.shutdownNow()
        }
    }
}
