package br.com.flowbiz.onsite

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FlowbizCoreLifecycleTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun harness() = CoreHarness(temp.newFolder())

    private fun pingEntries(h: CoreHarness): List<JSONObject> =
        h.sentEntries().filter { it.getString("event") == "page.ping" }

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
        h.core.onForeground()
        assertEquals(1, h.scheduler.scheduled.count { it.repeating && !it.cancelled })
    }

    @Test
    fun pingBypassesQueueAndDedupAndCarriesSessionIdentity() {
        val h = harness()
        h.core.onForeground()
        h.scheduler.tickRepeating(2)

        val pings = pingEntries(h)
        assertEquals(2, pings.size)
        assertEquals(0, h.queue.size)

        val ping = pings.first()
        assertEquals("{}", ping.getString("data"))
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
        h.core.track(Event.PageView(path = "/checkout", title = "checkout"))
        h.scheduler.tickRepeating()
        assertEquals(
            """{"page":{"title":"checkout","url":"https://store.com/checkout"}}""",
            pingEntries(h).last().getString("data"),
        )

        h.core.track(Event.PageView())
        h.scheduler.tickRepeating()
        assertEquals(
            """{"page":{"title":"checkout","url":"https://store.com/checkout"}}""",
            pingEntries(h).last().getString("data"),
        )
    }

    @Test
    fun pingAndRawEventsCarryContextFields() {
        val h = CoreHarness(
            temp.newFolder(),
            config = FlowbizConfig(appId = "77777", baseUri = "https://store.com", recoveryUrl = "https://store.com/carrinho"),
        )
        h.core.onForeground()
        h.core.track(Event.PageView(path = "/home"))
        h.scheduler.tickRepeating()
        val ping = pingEntries(h).last()
        val context = ping.getJSONObject("context")
        assertEquals("https://store.com/home", context.getString("url"))
        assertEquals("https://store.com", context.getString("baseuri"))
        assertEquals("https://store.com/carrinho", context.getString("recoveryUrl"))

        h.core.setPushToken("tok")
        val sync = h.sentEntries().last { it.getString("event") == "push.token.sync" }
        val syncContext = sync.getJSONObject("context")
        assertEquals("https://store.com/home", syncContext.getString("url"))
        assertEquals("https://store.com", syncContext.getString("baseuri"))
        assertEquals("https://store.com/carrinho", syncContext.getString("recoveryUrl"))
    }

    @Test
    fun titleOnlyPageViewOmitsContextUrlButKeepsPingTitle() {
        val h = harness()
        h.core.onForeground()
        h.core.track(Event.PageView(path = null, title = "Só título"))

        val tracked = h.lastEntry()
        assertFalse(tracked.getJSONObject("context").has("url"))

        h.scheduler.tickRepeating()
        val ping = pingEntries(h).last()
        assertFalse(ping.getJSONObject("context").has("url"))
        assertEquals("""{"page":{"title":"Só título"}}""", ping.getString("data"))
    }

    @Test
    fun pingFailureIsDroppedNeverQueued() {
        val h = harness()
        h.core.onForeground()
        h.sender.defaultResult = SendResult.RETRIABLE_ERROR
        h.scheduler.tickRepeating(3)
        assertEquals(0, h.queue.size)
        assertEquals(3, pingEntries(h).size)
    }

    @Test
    fun pingKeepsSessionAliveAsActivity() {
        val h = harness()
        h.core.track(Event.PageView("home"))
        val sessionBefore = h.lastEntry().getJSONObject("identity").getString("session_id")
        h.core.onForeground()
        repeat(3) {
            h.clock.advance(25 * MINUTE_MS)
            h.scheduler.tickRepeating()
        }
        h.clock.advance(25 * MINUTE_MS)
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

    @Test
    fun setEnabledFalseStopsHeartbeatDropsEventsAndGatesNetwork() {
        val h = harness()
        h.core.onForeground()
        h.sender.defaultResult = SendResult.RETRIABLE_ERROR
        h.core.track(Event.PageView("home"))
        assertEquals(1, h.queue.size)
        val sendsBefore = h.sender.bodies.size

        h.core.setEnabled(false)
        assertEquals(false, h.store.values[StorageKeys.ENABLED])
        assertNull(h.scheduler.activeRepeating())

        h.core.track(Event.PageView("dropped"))
        assertEquals(1, h.queue.size)

        h.core.flush()
        h.scheduler.runLastScheduled()
        assertEquals(sendsBefore, h.sender.bodies.size)
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
        assertEquals(0, h.queue.size)
        assertNotNull(h.scheduler.activeRepeating())
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
