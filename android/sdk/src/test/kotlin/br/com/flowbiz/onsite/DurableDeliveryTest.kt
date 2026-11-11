package br.com.flowbiz.onsite

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

// Real threads: what these pin is which thread a blocking send holds.
class DurableDeliveryTest {

    @get:Rule
    val temp = TemporaryFolder()

    private val executors = mutableListOf<ScheduledExecutorService>()

    private fun serialScheduler(): TaskScheduler =
        ExecutorTaskScheduler(Executors.newSingleThreadScheduledExecutor().also { executors += it })

    @After
    fun shutDown() = executors.forEach { it.shutdownNow() }

    private class BlockingSender : HttpSender {
        val bodies = CopyOnWriteArrayList<String>()
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)

        override fun send(body: String): SendResult {
            bodies += body
            started.countDown()
            release.await(10, TimeUnit.SECONDS)
            return SendResult.SUCCESS
        }
    }

    private fun core(queueFile: File, sender: HttpSender) = FlowbizCore(
        config = FlowbizConfig(appId = "77777", baseUri = "https://store.com"),
        store = FakeKeyValueStore(),
        queueFactory = { EventQueue(queueFile) },
        pushTokenFile = { File(queueFile.parentFile, "push_token") },
        sender = sender,
        scheduler = serialScheduler(),
        clock = FakeClock(),
        deviceContext = FakeDeviceContext(),
        reachability = FakeReachability(),
        transportScheduler = serialScheduler(),
    )

    private fun awaitLines(file: File, count: Int): List<String> {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
        while (System.nanoTime() < deadline) {
            val lines = if (file.exists()) file.readLines() else emptyList()
            if (lines.size >= count) return lines
            Thread.sleep(10)
        }
        return if (file.exists()) file.readLines() else emptyList()
    }

    @Test(timeout = 20_000)
    fun anEventTrackedWhileASendIsBlockedIsOnDiskBeforeThatSendReturns() {
        val queueFile = File(temp.newFolder(), "queue.jsonl")
        val sender = BlockingSender()
        val core = core(queueFile, sender)

        core.track(Event.PageView("/first"))
        assertTrue(sender.started.await(5, TimeUnit.SECONDS))
        core.track(Event.CartSetCoupon(cartId = "c-1", coupon = "tracked-mid-send"))

        val lines = awaitLines(queueFile, 2)
        assertEquals("the send is still blocked", 1L, sender.release.count)
        assertEquals(2, lines.size)
        assertTrue(lines[1], "tracked-mid-send" in lines[1])
        sender.release.countDown()
    }

    @Test(timeout = 20_000)
    fun anEventTrackedWhileAPingIsBlockedIsOnDiskBeforeThatPingReturns() {
        val queueFile = File(temp.newFolder(), "queue.jsonl")
        val sender = object : HttpSender {
            val pingStarted = CountDownLatch(1)
            val release = CountDownLatch(1)

            override fun send(body: String): SendResult {
                if ("page.ping" in body) {
                    pingStarted.countDown()
                    release.await(10, TimeUnit.SECONDS)
                }
                return SendResult.RETRIABLE_ERROR
            }
        }
        val core = FlowbizCore(
            config = FlowbizConfig(appId = "77777", baseUri = "https://store.com", heartbeatIntervalSeconds = 15),
            store = FakeKeyValueStore(),
            queueFactory = { EventQueue(queueFile) },
            pushTokenFile = { File(queueFile.parentFile, "push_token") },
            sender = sender,
            scheduler = object : TaskScheduler by serialScheduler() {
                private val real = serialScheduler()
                override fun execute(task: Runnable) = real.execute(task)
                override fun schedule(delayMillis: Long, task: Runnable) = real.schedule(delayMillis, task)
                override fun scheduleRepeating(intervalMillis: Long, task: Runnable) = real.scheduleRepeating(20, task)
            },
            clock = FakeClock(),
            deviceContext = FakeDeviceContext(),
            reachability = FakeReachability(),
            transportScheduler = serialScheduler(),
        )
        core.onForeground()
        assertTrue(sender.pingStarted.await(5, TimeUnit.SECONDS))
        core.track(Event.PageView("/tracked-mid-ping"))

        val lines = awaitLines(queueFile, 1)
        assertEquals("the ping is still blocked", 1L, sender.release.count)
        assertEquals(1, lines.size)
        sender.release.countDown()
    }
}
