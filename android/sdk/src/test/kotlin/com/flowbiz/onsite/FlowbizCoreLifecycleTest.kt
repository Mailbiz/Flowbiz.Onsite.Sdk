package com.flowbiz.onsite

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * [FlowbizCore] lifecycle wiring: heartbeat start/stop on
 * foreground/background (SPEC §8), ping contents and session keepalive
 * (SPEC §6), and the SPEC §12 `setEnabled` behavior (drop, stop, gate,
 * resume).
 */
class FlowbizCoreLifecycleTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun harness() = CoreHarness(temp.newFolder())

    private fun pingEntries(h: CoreHarness): List<JSONObject> =
        h.sentEntries().filter { it.getString("event") == "page.ping" }

    // --- Heartbeat lifecycle (SPEC §8) ---

    @Test
    fun foregroundStartsHeartbeatWithConfiguredInterval() {
        val h = harness()
        assertNull(h.scheduler.activeRepeating())
        h.core.onForeground()
        val repeating = h.scheduler.activeRepeating()
        assertNotNull(repeating)
        assertEquals(60_000L, repeating!!.delayMillis)
    }

    @Test
    fun heartbeatIntervalComesFromConfig() {
        val h = CoreHarness(
            temp.newFolder(),
            config = FlowbizConfig(appId = "77777", baseUri = "https://store.com", heartbeatIntervalSeconds = 15),
        )
        h.core.onForeground()
        assertEquals(15_000L, h.scheduler.activeRepeating()!!.delayMillis)
    }

    @Test
    fun backgroundStopsHeartbeat() {
        val h = harness()
        h.core.onForeground()
        h.core.onBackground()
        assertNull(h.scheduler.activeRepeating())
    }

    @Test
    fun redundantForegroundDoesNotRestartHeartbeat() {
        val h = harness()
        h.core.onForeground()
        h.core.onForeground() // e.g. didBecomeActive after the initial probe
        assertEquals(1, h.scheduler.scheduled.count { it.repeating && !it.cancelled })
    }

    @Test
    fun pingBypassesQueueAndDedupAndCarriesSessionIdentity() {
        val h = harness()
        h.core.onForeground()
        h.scheduler.tickRepeating(2) // identical beats: dedup-exempt by design

        val pings = pingEntries(h)
        assertEquals(2, pings.size)
        assertEquals(0, h.queue.size) // never persisted (SPEC §8)

        val ping = pings.first()
        assertEquals("{}", ping.getString("data")) // no named pageView yet
        val identity = ping.getJSONObject("identity")
        assertTrue(IdentityStore.UUID_SHAPE.matches(identity.getString("anonymous_id")))
        assertTrue(IdentityStore.UUID_SHAPE.matches(identity.getString("session_id")))
        assertEquals("-03:00", ping.getJSONObject("timings").getString("timezone"))
        assertFalse(ping.getJSONObject("context").has("url"))
    }

    @Test
    fun pingCarriesLastTrackedScreenAsPageData() {
        val h = harness()
        h.core.onForeground()
        h.core.track(Event.PageView("checkout"))
        h.scheduler.tickRepeating()
        assertEquals(
            """{"page":{"title":"checkout","url":"app://checkout"}}""",
            pingEntries(h).last().getString("data"),
        )

        // An anonymous pageView does not clear the last named screen.
        h.core.track(Event.PageView())
        h.scheduler.tickRepeating()
        assertEquals(
            """{"page":{"title":"checkout","url":"app://checkout"}}""",
            pingEntries(h).last().getString("data"),
        )
    }

    @Test
    fun pingFailureIsDroppedNeverQueued() {
        val h = harness()
        h.core.onForeground()
        h.sender.defaultResult = SendResult.RETRIABLE_ERROR
        h.scheduler.tickRepeating(3)
        assertEquals(0, h.queue.size)
        assertEquals(3, pingEntries(h).size) // attempted, dropped, no retry state
    }

    @Test
    fun pingKeepsSessionAliveAsActivity() {
        // SPEC §6: page.ping counts as activity — a foregrounded idle app
        // keeps its session.
        val h = harness()
        h.core.track(Event.PageView("home"))
        val sessionBefore = h.lastEntry().getJSONObject("identity").getString("session_id")
        h.core.onForeground()
        repeat(3) {
            h.clock.advance(25 * MINUTE_MS)
            h.scheduler.tickRepeating()
        }
        h.clock.advance(25 * MINUTE_MS) // 25 < 30 since last ping
        h.core.track(Event.PageView("later"))
        assertEquals(sessionBefore, h.lastEntry().getJSONObject("identity").getString("session_id"))
    }

    @Test
    fun foregroundRequestsFlushOfBacklog() {
        val h = harness()
        h.sender.results.addLast(SendResult.RETRIABLE_ERROR)
        h.core.track(Event.PageView("home"))
        assertEquals(1, h.queue.size)
        h.core.onForeground()
        assertEquals(0, h.queue.size)
    }

    // --- setEnabled (SPEC §12) ---

    @Test
    fun setEnabledFalseStopsHeartbeatDropsEventsAndGatesNetwork() {
        val h = harness()
        h.core.onForeground()
        // Build a retriable backlog first (a retry is now scheduled).
        h.sender.defaultResult = SendResult.RETRIABLE_ERROR
        h.core.track(Event.PageView("home"))
        assertEquals(1, h.queue.size)
        val sendsBefore = h.sender.bodies.size

        h.core.setEnabled(false)
        assertEquals(false, h.store.values[StorageKeys.ENABLED]) // persisted
        assertNull(h.scheduler.activeRepeating()) // heartbeat stopped

        h.core.track(Event.PageView("dropped")) // dropped, not queued
        assertEquals(1, h.queue.size)

        h.core.flush() // ignored while disabled
        h.scheduler.runLastScheduled() // pending backoff retry fires → gated
        assertEquals(sendsBefore, h.sender.bodies.size) // zero network while disabled
    }

    @Test
    fun reachabilityWhileDisabledDoesNotTouchNetwork() {
        val h = harness()
        h.sender.results.addLast(SendResult.RETRIABLE_ERROR)
        h.core.track(Event.PageView("home"))
        val sendsBefore = h.sender.bodies.size
        h.core.setEnabled(false)
        h.reachability.callback!!.run()
        assertEquals(sendsBefore, h.sender.bodies.size)
    }

    @Test
    fun reEnableResumesHeartbeatAndFlushesBacklog() {
        val h = harness()
        h.core.onForeground()
        h.sender.defaultResult = SendResult.RETRIABLE_ERROR
        h.core.track(Event.PageView("home"))
        h.core.setEnabled(false)
        assertEquals(1, h.queue.size)

        h.sender.defaultResult = SendResult.SUCCESS
        h.core.setEnabled(true)
        assertEquals(0, h.queue.size) // backlog flushed
        assertNotNull(h.scheduler.activeRepeating()) // heartbeat resumed (foregrounded)
        assertEquals(true, h.store.values[StorageKeys.ENABLED])
    }

    @Test
    fun reEnableWhileBackgroundedDoesNotStartHeartbeat() {
        val h = harness()
        h.core.setEnabled(false)
        h.core.setEnabled(true)
        assertNull(h.scheduler.activeRepeating())
    }

    @Test
    fun foregroundWhileDisabledStartsNothing() {
        val h = harness()
        h.core.setEnabled(false)
        h.core.onForeground()
        assertNull(h.scheduler.activeRepeating())
        assertEquals(0, h.sender.bodies.size)
    }

    @Test
    fun disabledStatePersistsAcrossCoreRecreation() {
        val store = FakeKeyValueStore()
        val first = CoreHarness(temp.newFolder(), store = store)
        first.core.setEnabled(false)

        val second = CoreHarness(temp.newFolder(), store = store)
        second.core.track(Event.PageView("home"))
        assertEquals(0, second.sender.bodies.size)
    }
}
