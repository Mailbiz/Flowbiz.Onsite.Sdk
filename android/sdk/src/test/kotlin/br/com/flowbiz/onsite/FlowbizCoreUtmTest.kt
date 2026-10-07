package br.com.flowbiz.onsite

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class FlowbizCoreUtmTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun harness(
        store: FakeKeyValueStore = FakeKeyValueStore(),
        clock: FakeClock = FakeClock(),
        appId: String = "77777",
    ) = CoreHarness(temp.newFolder(), FlowbizConfig(appId = appId, baseUri = "https://store.com"), store, clock)

    private val journey = FixtureSupport.utmExtractVectors().getValue("messagebuilder_journey_cart_recovery")
    private val link = journey.url!!
    private val utm = journey.expected!!

    private var probe = 0

    // A fresh coupon per probe: dedup would suppress a repeat.
    private fun CoreHarness.trackProbe(): String? {
        core.track(Event.CartSetCoupon(cartId = "c-1", coupon = "probe-${probe++}"))
        return lastEntry().utm()
    }

    private fun JSONObject.utm(): String? =
        getJSONObject("context").let { if (it.has("utm")) it.getString("utm") else null }

    private fun CoreHarness.last(event: String) = sentEntries().last { it.getString("event") == event }

    private fun CoreHarness.expiry() = store.values[StorageKeys.UTM_EXPIRES_AT_WALL_MS]

    private fun pushWith(deepLink: String?): FlowbizPush {
        val marker = JSONObject().put("v", 1).put("type", "cart_recovery")
        if (deepLink != null) marker.put("deep_link", deepLink)
        return Flowbiz.handlePush(mapOf("flowbiz" to marker.toString()))!!
    }

    private fun withInstalledCore(core: FlowbizCore, block: () -> Unit) {
        val field = Flowbiz::class.java.getDeclaredField("core").apply { isAccessible = true }
        check(field.get(null) == null) { "a core is already installed" }
        field.set(null, core)
        try {
            block()
        } finally {
            field.set(null, null)
        }
    }

    @Test
    fun aLinkPutsContextUtmOnEveryEntryBuiltAfterIt() {
        val h = harness()
        h.sender.results.addLast(SendResult.RETRIABLE_ERROR) // keeps this first event queued
        h.core.track(Event.CartSetCoupon(cartId = "c-1", coupon = "before"))

        assertEquals("cart-abc-001", Flowbiz.handleLink(link, h.core)?.cartId)
        assertEquals(utm, h.trackProbe())
        assertNull(h.sentEntries().last { "before" in it.getString("data") }.utm())

        h.core.onForeground()
        h.scheduler.tickRepeating()
        assertEquals(utm, h.last("page.ping").utm())
        h.core.setPushToken("tok")
        assertEquals(utm, h.last("push.token.sync").utm())
    }

    @Test(timeout = 15_000)
    fun handleLinkThenTrackFromTheSameThreadOnTheRealScheduler() {
        val executor = Executors.newSingleThreadScheduledExecutor()
        val release = CountDownLatch(1)
        executor.execute { release.await() }
        try {
            val sent = CountDownLatch(1)
            val sender = FakeHttpSender().apply { onSend = { sent.countDown() } }
            val queueFile = File(temp.newFolder(), "queue.jsonl")
            val store = FakeKeyValueStore()
            // Expired: the startup load discards it, so it outlives the constructor only if that load is deferred.
            val stale = """[["utm_source","stale"]]"""
            store.putString(StorageKeys.UTM_DATA, stale)
            store.putLong(StorageKeys.UTM_EXPIRES_AT_WALL_MS, 0L)
            val core = FlowbizCore(
                config = FlowbizConfig(appId = "77777", baseUri = "https://store.com"),
                store = store,
                queueFactory = { EventQueue(queueFile) },
                sender = sender,
                scheduler = ExecutorTaskScheduler(executor),
                clock = FakeClock(),
                deviceContext = FakeDeviceContext(),
                reachability = FakeReachability(),
            )
            Flowbiz.handleLink(link, core)
            core.track(Event.PageView(path = "/carrinho"))
            assertEquals("loaded or captured on the caller's thread", stale, store.values[StorageKeys.UTM_DATA])
            release.countDown()

            assertTrue(sent.await(10, TimeUnit.SECONDS))
            val body = executor.submit<String> { sender.bodies.single() }.get()
            assertEquals(utm, JSONObject(body).getJSONArray("data").getJSONObject(0).utm())
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun everySequenceVectorHoldsThroughTheCoreAndARestart() {
        for ((name, steps) in FixtureSupport.utmSequenceVectors()) {
            val h = harness()
            h.core.onForeground()
            steps.forEachIndexed { i, step ->
                if (step.url != null) {
                    Flowbiz.handleLink(step.url, h.core)
                } else {
                    h.core.onBackground()
                    h.core.onForeground()
                }
                assertEquals("$name[$i]", step.expected, h.trackProbe())
            }
            assertEquals("$name after a restart", steps.last().expected, harness(h.store, h.clock).trackProbe())
        }
    }

    @Test
    fun theEnvelopeVectorPinsContextUtmEscaping() {
        val envelope = FixtureSupport.utmEnvelopeVector()
        val h = harness()
        Flowbiz.handleLink(envelope.getString("url"), h.core)
        assertEquals(envelope.getString("utm"), h.trackProbe())

        val utmMember = envelope.getString("context_canonical").removePrefix("{").removeSuffix("}")
        assertTrue(h.sender.bodies.last(), utmMember in h.sender.bodies.last())
    }

    @Test
    fun visitsSlideTheExpiryStartupDoesNotAndAnExpiredSetIsDropped() {
        val h = harness()
        Flowbiz.handleLink(link, h.core)
        assertEquals(h.clock.wall + 30 * DAY_MS, h.expiry())
        h.clock.advance(10 * DAY_MS)
        h.core.onForeground()
        assertEquals(h.clock.wall + 30 * DAY_MS, h.expiry())
        val lastVisit = h.clock.wall

        h.clock.advance(10 * DAY_MS)
        val restarted = harness(h.store, h.clock)
        assertEquals(utm, restarted.trackProbe())
        assertEquals(lastVisit + 30 * DAY_MS, restarted.expiry())

        h.clock.advance(20 * DAY_MS)
        assertEquals(utm, restarted.trackProbe())
        restarted.core.onForeground()
        assertNull(restarted.trackProbe())
        assertNull(restarted.store.values[StorageKeys.UTM_DATA])
        assertNull(restarted.expiry())
    }

    @Test
    fun aLinkCapturedWhileDisabledIsStoredAndSentOnceReEnabled() {
        val h = harness()
        h.core.setEnabled(false)
        h.core.setPushToken("tok")
        Flowbiz.handleLink(link, h.core)
        h.core.track(Event.PageView(path = "/carrinho"))
        assertTrue(h.sender.bodies.isEmpty())
        assertTrue(StorageKeys.UTM_DATA in h.store.values)

        h.core.setEnabled(true)
        assertEquals(utm, h.last("push.token.sync").utm())
        assertEquals(utm, h.trackProbe())
    }

    @Test
    fun logoutKeepsTheUtms() {
        val h = harness()
        h.core.track(Event.AccountLogin(User(userId = "u-1", email = "u1@example.com")))
        h.core.setPushToken("tok")
        Flowbiz.handleLink(link, h.core)
        h.core.logout()

        assertEquals(utm, h.last("push.token.remove").utm())
        assertEquals(utm, h.trackProbe())
        assertEquals(utm, harness(h.store, h.clock).trackProbe())
    }

    @Test
    fun captureDoesNotDependOnTheRecoveryDecode() {
        val thirdParty = FixtureSupport.utmExtractVectors().getValue("third_party_campaign")
        val cases = listOf(
            Triple("77777", thirdParty.url!!, thirdParty.expected),
            Triple("77777", link.replace("utm_source=flowbiz", "utm_source=google"), utm.replace("flowbiz", "google")),
            Triple("88888", link, utm),
        )
        for ((appId, url, expected) in cases) {
            val h = harness(appId = appId)
            assertNull(url, Flowbiz.handleLink(url, h.core))
            assertEquals(url, expected, h.trackProbe())
        }
    }

    @Test
    fun handlePushOpenedCapturesTheRawDeepLinkAndHandlePushNothing() {
        val h = harness()
        withInstalledCore(h.core) {
            val push = pushWith(link)
            assertNull(h.trackProbe())
            assertNull(Flowbiz.handlePushOpened(pushWith(null)))
            assertEquals("cart-abc-001", Flowbiz.handlePushOpened(push)?.cartId)
        }
        assertEquals(utm, h.trackProbe())
    }

    @Test
    fun beforeInitializeALinkIsOnlyDecoded() {
        val logs = mutableListOf<String>()
        SdkLog.sink = { logs += it }
        try {
            assertEquals("cart-abc-001", Flowbiz.handleLink(link, current = null)?.cartId)
            assertEquals("cart-abc-001", Flowbiz.handlePushOpened(pushWith(link))?.cartId)
        } finally {
            SdkLog.sink = null
        }
        assertTrue(logs.toString(), logs.isEmpty())
    }

    @Test
    fun theLandingPageViewCarriesANewCaptureWhileAnIdenticalPayloadStaysDeduped() {
        val h = harness()
        val coupon = Event.CartSetCoupon(cartId = "c-1", coupon = "same")
        h.core.track(Event.PageView(path = "/carrinho"))
        h.core.track(coupon)
        Flowbiz.handleLink(link, h.core)
        h.clock.advance(MINUTE_MS)
        h.core.track(Event.PageView(path = "/carrinho"))
        h.core.track(coupon)

        assertEquals(3, h.sentEntries().size)
        assertEquals(utm, h.last("page.view").utm())
    }
}
