package com.flowbiz.onsite

import org.json.JSONObject
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * [FlowbizCore] track pipeline (SPEC §5/§4/§6): envelope contents,
 * identity side effects, session sliding/rotation, timezone rendering,
 * logout, the never-throw boundary, and explicit flush.
 */
class FlowbizCoreTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun harness(configure: (TemporaryFolder) -> CoreHarness = { CoreHarness(it.newFolder()) }): CoreHarness =
        configure(temp)

    private val user = User(userId = "98412", email = "maria.oliveira@gmail.com")

    // --- Envelope pipeline ---

    @Test
    fun trackedEnvelopeCarriesIdentitySessionContextAndData() {
        val h = harness()
        h.core.track(Event.PageView("home"))

        val entry = h.lastEntry()
        assertEquals("page.view", entry.getString("event"))
        assertEquals("77777", entry.getString("app_id"))
        assertEquals("android", entry.getString("platform"))
        assertEquals("flowbiz-android-sdk", entry.getString("v_tracker"))
        assertEquals("android-${SdkVersion.CURRENT}", entry.getString("v_version"))
        assertTrue(IdentityStore.UUID_SHAPE.matches(entry.getString("hash")))

        val identity = entry.getJSONObject("identity")
        assertFalse(identity.has("user_id")) // no login yet → omitted
        assertTrue(IdentityStore.UUID_SHAPE.matches(identity.getString("anonymous_id")))
        assertTrue(IdentityStore.UUID_SHAPE.matches(identity.getString("session_id")))
        assertEquals(1, identity.getInt("visit_count"))

        val context = entry.getJSONObject("context")
        assertEquals("android", context.getString("platform"))
        assertEquals("pt-BR", context.getString("language"))
        assertEquals("1080x2400", context.getString("screen"))
        assertEquals("flowbiz-android-sdk", context.getString("vendor"))
        assertEquals(SdkVersion.CURRENT, context.getString("onsite_version"))
        assertEquals("app://home", context.getString("url"))

        val timings = entry.getJSONObject("timings")
        val expectedIso = EnvelopeBuilder.isoMillis(h.clock.wall)
        assertEquals(expectedIso, timings.getString("created_at"))
        assertEquals(expectedIso, timings.getString("sent_at"))
        assertEquals("-03:00", timings.getString("timezone"))

        assertEquals(EventSerializer.dataJson(Event.PageView("home")), entry.getString("data"))
    }

    @Test
    fun trackedEnvelopeDataMatchesSharedFixture() {
        // Drift-guard reuse: the pipeline must ship the exact canonical data
        // string the shared fixture pins for both platforms.
        val h = harness()
        val fixture = JSONObject(File(FixtureSupport.fixturesDir(), "cart_sync_full.json").readText())
        val event = FixtureSupport.buildEvent(fixture.getString("event"), fixture.getJSONObject("input"))
        h.core.track(event)

        val expected = fixture.getJSONObject("expected")
        assertEquals(expected.getString("wire_event"), h.lastEntry().getString("event"))
        assertEquals(expected.getString("data_canonical"), h.lastEntry().getString("data"))
    }

    @Test
    fun pageViewWithoutScreenNameHasNoContextUrl() {
        val h = harness()
        h.core.track(Event.PageView())
        assertFalse(h.lastEntry().getJSONObject("context").has("url"))
    }

    @Test
    fun trackedEventIsQueuedThenDrainedBySuccessfulFlush() {
        val h = harness()
        h.core.track(Event.PageView("home"))
        assertEquals(0, h.queue.size) // drained inline by the flush
        assertEquals(1, h.sender.bodies.size)
    }

    // --- Identity side effects (SPEC §5/§6) ---

    @Test
    fun accountLoginSetsUserIdOnItselfAndSubsequentEvents() {
        val h = harness()
        h.core.track(Event.AccountLogin(user))
        assertEquals("98412", h.lastEntry().getJSONObject("identity").getString("user_id"))

        h.core.track(Event.PageView("home"))
        assertEquals("98412", h.lastEntry().getJSONObject("identity").getString("user_id"))
        assertEquals("98412", h.store.values[StorageKeys.USER_ID])
        assertEquals("maria.oliveira@gmail.com", h.store.values[StorageKeys.EMAIL])
    }

    @Test
    fun accountSyncAlsoStoresIdentity() {
        val h = harness()
        h.core.track(Event.AccountSync(user))
        assertEquals("98412", h.lastEntry().getJSONObject("identity").getString("user_id"))
    }

    @Test
    fun logoutClearsUserRotatesSessionAndClearsPushToken() {
        val h = harness()
        h.store.values[StorageKeys.PUSH_TOKEN] = "fcm-token-1"
        h.core.track(Event.AccountLogin(user))
        val before = h.lastEntry().getJSONObject("identity")

        h.core.logout()
        // Slice 5 will emit push.token.remove here; for now only state changes.
        h.core.track(Event.PageView("home"))
        val after = h.lastEntry().getJSONObject("identity")

        assertFalse(after.has("user_id"))
        assertNotEquals(before.getString("session_id"), after.getString("session_id"))
        assertEquals(before.getInt("visit_count") + 1, after.getInt("visit_count"))
        // anonymous_id survives logout
        assertEquals(before.getString("anonymous_id"), after.getString("anonymous_id"))
        assertFalse(h.store.values.containsKey(StorageKeys.PUSH_TOKEN))
        assertFalse(h.store.values.containsKey(StorageKeys.USER_ID))
        assertFalse(h.store.values.containsKey(StorageKeys.EMAIL))
    }

    // --- Session semantics (SPEC §6) ---

    @Test
    fun everyTrackSlidesTheSessionWindow() {
        val h = harness()
        h.core.track(Event.PageView("a"))
        val first = h.lastEntry().getJSONObject("identity")

        // 20 min steps never expire a 30-min sliding window.
        repeat(3) {
            h.clock.advance(20 * MINUTE_MS)
            h.core.track(Event.PageView("screen-$it"))
        }
        val last = h.lastEntry().getJSONObject("identity")
        assertEquals(first.getString("session_id"), last.getString("session_id"))
        assertEquals(first.getInt("visit_count"), last.getInt("visit_count"))
    }

    @Test
    fun trackAfterThirtyIdleMinutesRotatesSession() {
        val h = harness()
        h.core.track(Event.PageView("a"))
        val first = h.lastEntry().getJSONObject("identity")

        h.clock.advance(31 * MINUTE_MS)
        h.core.track(Event.PageView("b"))
        val second = h.lastEntry().getJSONObject("identity")

        assertNotEquals(first.getString("session_id"), second.getString("session_id"))
        assertEquals(first.getInt("visit_count") + 1, second.getInt("visit_count"))
    }

    // --- Timezone (SPEC §4, first real use of the timezone param) ---

    @Test
    fun timezoneOffsetsRenderAsSignedHoursMinutes() {
        val cases = mapOf(
            0 to "+00:00",       // UTC
            -180 to "-03:00",    // São Paulo
            330 to "+05:30",     // India (half-hour zone)
            -570 to "-09:30",    // Marquesas (negative half-hour)
            345 to "+05:45",     // Nepal (quarter-hour)
            840 to "+14:00",     // Line Islands
        )
        val h = harness()
        for ((minutes, expected) in cases) {
            h.device.offsetMinutes = minutes
            // distinct payloads: dedup must not eat the later samples
            h.core.track(Event.PageView("screen-$minutes"))
            assertEquals(expected, h.lastEntry().getJSONObject("timings").getString("timezone"))
            assertEquals(expected, FlowbizCore.formatTimezoneOffset(minutes))
        }
    }

    // --- Never-throw boundary (SPEC §3) ---

    @Test
    fun nanPriceEventIsDroppedAndNextEventIsFine() {
        val h = harness()
        val poison = Event.ProductView(
            Product(productId = "P1", variants = listOf(ProductVariant(sku = "S1", price = Double.NaN)))
        )
        h.core.track(poison) // must not throw
        assertEquals(0, h.sender.bodies.size)
        assertEquals(0, h.queue.size)

        h.core.track(Event.PageView("recovered"))
        assertEquals(1, h.sender.bodies.size)
        assertEquals("page.view", h.lastEntry().getString("event"))
    }

    @Test
    fun throwingSchedulerNeverEscapesTheEntryPoints() {
        val throwing = object : TaskScheduler {
            override fun execute(task: Runnable) = throw IllegalStateException("boom")
            override fun schedule(delayMillis: Long, task: Runnable): ScheduledHandle =
                throw IllegalStateException("boom")
            override fun scheduleRepeating(intervalMillis: Long, task: Runnable): ScheduledHandle =
                throw IllegalStateException("boom")
        }
        val h = harness { CoreHarness(it.newFolder(), scheduler = FakeTaskScheduler()) }
        val core = FlowbizCore(
            config = h.config,
            store = FakeKeyValueStore(),
            queueFactory = { h.queue },
            sender = h.sender,
            scheduler = throwing,
            clock = h.clock,
            deviceContext = h.device,
            reachability = FakeReachability(),
        )
        core.track(Event.PageView("home")) // must not throw
        core.logout()
        core.setEnabled(false)
        core.flush()
        core.onForeground()
        core.onBackground()
    }

    // --- Explicit flush (SPEC §2) ---

    @Test
    fun explicitFlushDrainsARetriableBacklog() {
        val h = harness()
        h.sender.results.addLast(SendResult.RETRIABLE_ERROR)
        h.core.track(Event.PageView("home")) // first attempt fails, stays queued
        assertEquals(1, h.queue.size)

        h.core.flush() // default result SUCCESS
        assertEquals(0, h.queue.size)
        assertEquals(2, h.sender.bodies.size)
    }

    @Test
    fun networkRestorationDrainsBacklogWhenEnabled() {
        val h = harness()
        assertTrue(h.reachability.started)
        h.sender.results.addLast(SendResult.RETRIABLE_ERROR)
        h.core.track(Event.PageView("home"))
        assertEquals(1, h.queue.size)

        h.reachability.callback!!.run()
        assertEquals(0, h.queue.size)
    }
}
