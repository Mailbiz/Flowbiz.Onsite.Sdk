package br.com.flowbiz.onsite

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * SPEC §8 heartbeat: repeating beats while started, stop halts, and the
 * fire-and-forget contract — failures drop, nothing ever touches the queue.
 */
class HeartbeatSchedulerTest {

    @get:Rule
    val temp = TemporaryFolder()

    private val scheduler = FakeTaskScheduler()
    private val sender = FakeHttpSender()

    private var pingCounter = 0
    private var provideNull = false

    private val heartbeat = HeartbeatScheduler(scheduler, sender) {
        if (provideNull) null else """{"event":"page.ping","hash":"ping${++pingCounter}"}"""
    }

    @Test
    fun firesAtEveryIntervalWhileStarted() {
        heartbeat.start(60_000)
        assertEquals(60_000L, scheduler.activeRepeating()?.delayMillis)
        scheduler.tickRepeating(3)
        assertEquals(
            listOf(
                """{"data":[{"event":"page.ping","hash":"ping1"}]}""",
                """{"data":[{"event":"page.ping","hash":"ping2"}]}""",
                """{"data":[{"event":"page.ping","hash":"ping3"}]}""",
            ),
            sender.bodies
        )
    }

    @Test
    fun stopCancelsTheTimer() {
        heartbeat.start(60_000)
        val handle = scheduler.activeRepeating()!!
        heartbeat.stop()
        assertTrue(handle.cancelled)
        assertNull(scheduler.activeRepeating())
    }

    @Test
    fun restartReplacesTheTimer() {
        heartbeat.start(60_000)
        val first = scheduler.activeRepeating()!!
        heartbeat.start(15_000)
        assertTrue(first.cancelled)
        assertEquals(15_000L, scheduler.activeRepeating()?.delayMillis)
    }

    @Test
    fun stopWithoutStartIsHarmless() {
        heartbeat.stop()
        assertEquals(0, sender.bodies.size)
    }

    @Test
    fun sendFailureIsDroppedAndNeverEnqueued() {
        // A durable queue co-exists; a failing heartbeat must never reach it
        // (SPEC §8: dropped on failure, never persisted, no retry).
        val queueFile = File(temp.newFolder(), "queue.jsonl")
        val queue = EventQueue(queueFile)
        sender.defaultResult = SendResult.RETRIABLE_ERROR
        heartbeat.start(60_000)
        scheduler.tickRepeating(2)
        assertEquals(2, sender.bodies.size)
        assertEquals(0, queue.size)
        assertFalse(queueFile.exists())
        // No retry machinery engaged either.
        assertTrue(scheduler.allScheduleDelays.isEmpty())
    }

    @Test
    fun nullEnvelopeSkipsTheBeat() {
        provideNull = true
        heartbeat.start(60_000)
        scheduler.tickRepeating(2)
        assertEquals(0, sender.bodies.size)
    }

    // --- page.ping envelope shape (SPEC §8: not part of the Event catalog) ---

    @Test
    fun buildPingProducesAPingEnvelopeWithEmptyPayload() {
        val entry = EnvelopeBuilder.buildPing(
            hash = "abc",
            createdAtMillis = 1_700_000_000_000L,
            sentAtMillis = 1_700_000_000_123L,
            timezone = "-03:00",
            userId = "u1",
            anonymousId = "anon",
            sessionId = "sess",
            visitCount = 3,
            language = "pt-BR",
            screen = "1080x2400",
            appId = "77777",
            platform = "android",
            sdkVersion = "1.0.0",
        )
        assertEquals("page.ping", entry.getString("event"))
        assertEquals("{}", entry.getString("data"))
        assertEquals("abc", entry.getString("hash"))
        assertEquals("77777", entry.getString("app_id"))
        val context = entry.getJSONObject("context")
        assertFalse(context.has("url"))
        assertEquals("flowbiz-android-sdk", context.getString("vendor"))
        val timings = entry.getJSONObject("timings")
        assertEquals("2023-11-14T22:13:20.000Z", timings.getString("created_at"))
        assertEquals("2023-11-14T22:13:20.123Z", timings.getString("sent_at"))
        assertEquals("u1", entry.getJSONObject("identity").getString("user_id"))
        assertEquals(3, entry.getJSONObject("identity").getInt("visit_count"))
        // Round-trips through the canonical renderer like any queued entry.
        JSONObject(CanonicalJson.render(entry))
    }
}
