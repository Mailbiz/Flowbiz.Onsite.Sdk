package br.com.flowbiz.onsite

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class FlushControllerTest {

    @get:Rule
    val temp = TemporaryFolder()

    private val scheduler = FakeTaskScheduler()
    private val sender = FakeHttpSender()
    private val clock = FakeClock()
    private lateinit var queue: EventQueue

    private fun controller(batchSize: Int = FlushController.MAX_BATCH_SIZE): FlushController {
        queue = EventQueue(File(temp.newFolder(), "queue.jsonl"))
        return FlushController(queue, sender, scheduler, clock, batchSize)
    }

    private fun entry(n: Int): String = CanonicalJson.render(
        JSONObject()
            .put("event", "e$n")
            .put("hash", "h$n")
            .put(
                "timings",
                JSONObject()
                    .put("created_at", EnvelopeBuilder.isoMillis(clock.wall))
                    .put("sent_at", EnvelopeBuilder.isoMillis(clock.wall))
                    .put("timezone", "-03:00")
            )
    )

    private fun eventsIn(body: String): List<String> {
        val data = JSONObject(body).getJSONArray("data")
        return (0 until data.length()).map { data.getJSONObject(it).getString("event") }
    }

    private fun timingsOf(body: String, index: Int): JSONObject =
        JSONObject(body).getJSONArray("data").getJSONObject(index).getJSONObject("timings")

    @Test
    fun drainBatchesAtMostFiftyPerRequestInOrder() {
        val c = controller()
        (1..120).forEach { queue.append(entry(it)) }
        c.requestFlush(FlushController.FlushReason.EXPLICIT)
        assertEquals(3, sender.bodies.size)
        assertEquals(listOf(50, 50, 20), sender.bodies.map { eventsIn(it).size })
        assertEquals((1..50).map { "e$it" }, eventsIn(sender.bodies[0]))
        assertEquals((51..100).map { "e$it" }, eventsIn(sender.bodies[1]))
        assertEquals((101..120).map { "e$it" }, eventsIn(sender.bodies[2]))
        assertEquals(0, queue.size)
    }

    @Test
    fun successDequeuesExactlyTheBatch() {
        val c = controller(batchSize = 3)
        (1..5).forEach { queue.append(entry(it)) }
        sender.results.addAll(listOf(SendResult.SUCCESS, SendResult.RETRIABLE_ERROR))
        c.requestFlush(FlushController.FlushReason.EXPLICIT)
        assertEquals(listOf(entry(4), entry(5)), queue.peek(10))
    }

    @Test
    fun emptyQueueDrainSendsNothing() {
        val c = controller()
        c.requestFlush(FlushController.FlushReason.EXPLICIT)
        assertEquals(0, sender.bodies.size)
        assertTrue(scheduler.allScheduleDelays.isEmpty())
    }

    @Test
    fun payloadTooLargeSplitsInHalfUntilDeliverable() {
        val c = controller()
        (1..4).forEach { queue.append(entry(it)) }
        sender.resultFor = { body ->
            if (eventsIn(body).size > 1) SendResult.PAYLOAD_TOO_LARGE else SendResult.SUCCESS
        }
        c.requestFlush(FlushController.FlushReason.EXPLICIT)
        assertEquals(
            listOf(listOf("e1", "e2", "e3", "e4"), listOf("e1", "e2"), listOf("e1"), listOf("e2"), listOf("e3", "e4"), listOf("e3"), listOf("e4")),
            sender.bodies.map { eventsIn(it) }
        )
        assertEquals(0, queue.size)
    }

    @Test
    fun singleEventStill413IsDroppedAsPoison() {
        val c = controller()
        queue.append(entry(1))
        queue.append(entry(2))
        sender.resultFor = { body ->
            when {
                eventsIn(body).contains("e1") && eventsIn(body).size == 1 -> SendResult.PAYLOAD_TOO_LARGE
                eventsIn(body).size > 1 -> SendResult.PAYLOAD_TOO_LARGE
                else -> SendResult.SUCCESS
            }
        }
        c.requestFlush(FlushController.FlushReason.EXPLICIT)
        assertEquals(0, queue.size)
        assertTrue(scheduler.allScheduleDelays.isEmpty())
        assertEquals(listOf("e2"), eventsIn(sender.bodies.last()))
    }

    @Test
    fun permanentErrorBisectsToDropOnlyThePoisonEvent() {
        val c = controller()
        (1..5).forEach { queue.append(entry(it)) }
        sender.resultFor = { body ->
            if (eventsIn(body).contains("e3")) SendResult.PERMANENT_ERROR else SendResult.SUCCESS
        }
        c.requestFlush(FlushController.FlushReason.EXPLICIT)
        assertEquals(0, queue.size)
        val delivered = sender.bodies.filter { !eventsIn(it).contains("e3") }.flatMap { eventsIn(it) }
        assertEquals(listOf("e1", "e2", "e4", "e5"), delivered)
        assertTrue(scheduler.allScheduleDelays.isEmpty())
    }

    @Test
    fun wholeBatchPermanentlyRejectedIsDroppedEventByEvent() {
        val c = controller()
        (1..3).forEach { queue.append(entry(it)) }
        sender.defaultResult = SendResult.PERMANENT_ERROR
        c.requestFlush(FlushController.FlushReason.EXPLICIT)
        assertEquals(0, queue.size)
        assertTrue(scheduler.allScheduleDelays.isEmpty())
    }

    @Test
    fun retriableErrorStopsDrainPreservingOrderAndSchedulesRetry() {
        val c = controller(batchSize = 2)
        (1..5).forEach { queue.append(entry(it)) }
        sender.results.add(SendResult.SUCCESS)
        sender.defaultResult = SendResult.RETRIABLE_ERROR
        c.requestFlush(FlushController.FlushReason.EXPLICIT)
        assertEquals(listOf(entry(3), entry(4), entry(5)), queue.peek(10))
        assertEquals(2, sender.bodies.size)
        assertEquals(listOf(FlushController.INITIAL_BACKOFF_MS), scheduler.allScheduleDelays)
    }

    @Test
    fun retryDuringBisectionStopsWithoutDroppingInnocents() {
        val c = controller()
        (1..4).forEach { queue.append(entry(it)) }
        sender.results.add(SendResult.PERMANENT_ERROR)
        sender.defaultResult = SendResult.RETRIABLE_ERROR
        c.requestFlush(FlushController.FlushReason.EXPLICIT)
        assertEquals(4, queue.size)
        assertEquals(1, scheduler.allScheduleDelays.size)
    }

    @Test
    fun sentAtIsRewrittenOnEachAttemptCreatedAtUntouched() {
        val c = controller()
        val createdIso = EnvelopeBuilder.isoMillis(clock.wall)
        queue.append(entry(1))

        clock.advance(2_000)
        val firstAttemptIso = EnvelopeBuilder.isoMillis(clock.wall)
        sender.results.add(SendResult.RETRIABLE_ERROR)
        c.requestFlush(FlushController.FlushReason.EXPLICIT)

        clock.advance(5_000)
        val secondAttemptIso = EnvelopeBuilder.isoMillis(clock.wall)
        sender.defaultResult = SendResult.SUCCESS
        c.requestFlush(FlushController.FlushReason.EXPLICIT)

        assertEquals(2, sender.bodies.size)
        val first = timingsOf(sender.bodies[0], 0)
        val second = timingsOf(sender.bodies[1], 0)
        assertEquals(createdIso, first.getString("created_at"))
        assertEquals(createdIso, second.getString("created_at"))
        assertEquals(firstAttemptIso, first.getString("sent_at"))
        assertEquals(secondAttemptIso, second.getString("sent_at"))
        assertEquals("-03:00", second.getString("timezone"))
        assertEquals(0, queue.size)
    }

    @Test
    fun backoffDoublesToSixtySecondCap() {
        val c = controller()
        queue.append(entry(1))
        sender.defaultResult = SendResult.RETRIABLE_ERROR
        c.requestFlush(FlushController.FlushReason.EXPLICIT)
        repeat(7) { scheduler.runLastScheduled() }
        assertEquals(
            listOf(1_000L, 2_000L, 4_000L, 8_000L, 16_000L, 32_000L, 60_000L, 60_000L),
            scheduler.allScheduleDelays
        )
    }

    @Test
    fun anyRetryTriggerResetsBackoffAndCancelsPendingRetry() {
        val c = controller()
        queue.append(entry(1))
        sender.defaultResult = SendResult.RETRIABLE_ERROR
        c.requestFlush(FlushController.FlushReason.EXPLICIT)
        scheduler.runLastScheduled()
        scheduler.runLastScheduled()
        assertEquals(listOf(1_000L, 2_000L, 4_000L), scheduler.allScheduleDelays)

        c.requestFlush(FlushController.FlushReason.NETWORK_RESTORED)
        assertTrue(scheduler.scheduled[2].cancelled)
        assertEquals(listOf(1_000L, 2_000L, 4_000L, 1_000L), scheduler.allScheduleDelays)
    }

    @Test
    fun scheduledRetryAttemptsTheDrainAgain() {
        val c = controller()
        queue.append(entry(1))
        sender.results.add(SendResult.RETRIABLE_ERROR)
        sender.defaultResult = SendResult.SUCCESS
        c.requestFlush(FlushController.FlushReason.EXPLICIT)
        assertEquals(1, queue.size)
        scheduler.runLastScheduled()
        assertEquals(0, queue.size)
        assertEquals(2, sender.bodies.size)
    }

    @Test
    fun reentrantFlushRequestCoalescesInsteadOfNesting() {
        val c = controller()
        queue.append(entry(1))
        var triggered = false
        sender.onSend = {
            if (!triggered) {
                triggered = true
                c.requestFlush(FlushController.FlushReason.EVENT_TRACKED)
            }
        }
        c.requestFlush(FlushController.FlushReason.EXPLICIT)
        assertEquals(1, sender.maxDepth)
        assertEquals(1, sender.bodies.size)
        assertEquals(0, queue.size)
    }
}
