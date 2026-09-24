package br.com.flowbiz.onsite

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * [FlowbizCore] UTM attribution (SPEC §11.1): the read-only startup load,
 * the evaluation points ([FlowbizCore.captureUtm], foreground, re-enable
 * while foregrounded — a background re-enable only loads), `context.utm`
 * on every event, ping and internal event, the sliding 30-day expiry, the
 * disabled (expired-only purge) / logout rules, the facade's
 * [Flowbiz.handleLink] and [Flowbiz.handlePushOpened] capture rules
 * (through their seams, plus the public `handlePushOpened`'s hand-off of
 * the live core) and the hand-off to the scheduler. The extraction
 * rules themselves are pinned by `UtmLinkParserTest` against the
 * web-generated vectors.
 */
class FlowbizCoreUtmTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun harness(store: FakeKeyValueStore = FakeKeyValueStore(), clock: FakeClock = FakeClock()) =
        CoreHarness(temp.newFolder(), store = store, clock = clock)

    /** MessageBuilder's journey cart-recovery link and the web's exact `context.utm` for it. */
    private val journey = FixtureSupport.utmExtractVector("messagebuilder_journey_cart_recovery")
    private val link: String = journey.getString("url")
    private val expectedUtm: String = journey.getString("expected")

    /** Distinct payloads so dedup (SPEC §7) never suppresses a probe event. */
    private var probe = 0
    private fun nextEvent(): Event = Event.CartSetCoupon(cartId = "c-1", coupon = "probe-${probe++}")

    private fun JSONObject.utm(): String? =
        getJSONObject("context").let { if (it.has("utm")) it.getString("utm") else null }

    private fun FakeKeyValueStore.utmExpiry(): Any? = values[StorageKeys.UTM_EXPIRES_AT_WALL_MS]

    private fun assertNoUtmKeys(store: FakeKeyValueStore, message: String = "") {
        assertFalse(message, store.values.containsKey(StorageKeys.UTM_DATA))
        assertFalse(message, store.values.containsKey(StorageKeys.UTM_EXPIRES_AT_WALL_MS))
    }

    /**
     * A Flowbiz push (SPEC §10.2) whose `deep_link` is [deepLink] (absent
     * when null), through the real [Flowbiz.handlePush] parser.
     */
    private fun pushWith(deepLink: String?): FlowbizPush {
        val marker = JSONObject().put("v", 1).put("type", "cart_recovery")
        if (deepLink != null) marker.put("deep_link", deepLink)
        return Flowbiz.handlePush(mapOf("flowbiz" to marker.toString()))!!
    }

    // --- Capture → wire ---

    @Test
    fun captureThenTrackCarriesTheWebStringExactly() {
        val h = harness()
        h.core.captureUtm(link)
        h.core.track(Event.PageView(path = "/carrinho/recuperar", title = "Recuperação"))
        assertEquals(expectedUtm, h.lastEntry().utm())
        assertEquals(h.clock.wall + 30 * DAY_MS, h.store.utmExpiry())
    }

    @Test
    fun eventsBeforeAnyCaptureCarryNoUtm() {
        val h = harness()
        h.core.track(nextEvent())
        assertNull(h.lastEntry().utm())
        assertNoUtmKeys(h.store)
    }

    @Test
    fun pingAndInternalEventsCarryUtm() {
        val h = harness()
        h.core.captureUtm(link)
        h.core.onForeground()
        h.scheduler.tickRepeating()
        assertEquals(expectedUtm, h.sentEntries().last { it.getString("event") == "page.ping" }.utm())

        h.core.setPushToken("tok")
        assertEquals(expectedUtm, h.sentEntries().last { it.getString("event") == "push.token.sync" }.utm())
    }

    /** Context is stamped when the entry is built; flush only restamps `sent_at` (SPEC §11.1 item 5). */
    @Test
    fun aQueuedEntryKeepsTheContextItWasBuiltWith() {
        val h = harness()
        h.sender.results.addLast(SendResult.RETRIABLE_ERROR)
        h.core.track(Event.CartSetCoupon(cartId = "c-1", coupon = "queued-before-capture"))
        assertEquals(1, h.queue.size)

        h.core.captureUtm(link)
        h.core.flush()
        assertEquals(0, h.queue.size)
        val delivered = h.lastEntry()
        assertTrue(delivered.getString("data").contains("queued-before-capture"))
        assertNull(delivered.utm())

        h.core.track(nextEvent())
        assertEquals(expectedUtm, h.lastEntry().utm())
    }

    /** SPEC §11.1: capture never depends on the recovery decode — any link is a UTM source. */
    @Test
    fun linksWithoutRecoveryDataOrWithAForeignSourceStillCapture() {
        for (name in listOf("third_party_campaign", "legacy_newsletter_term_content_dropped", "custom_scheme_link")) {
            val vector = FixtureSupport.utmExtractVector(name)
            val h = harness()
            h.core.captureUtm(vector.getString("url"))
            h.core.track(nextEvent())
            assertEquals(name, vector.getString("expected"), h.lastEntry().utm())
        }
    }

    /**
     * The web sequences run through the real evaluation points: a url is a
     * [FlowbizCore.captureUtm], a null url a foreground edge (an evaluation
     * without a link); each step's next event carries the web's string.
     */
    @Test
    fun sharedSequencesHoldThroughTheCoreEvaluationPoints() {
        val sequences = FixtureSupport.utmLinkVectors().getJSONArray("sequences")
        for (s in 0 until sequences.length()) {
            val sequence = sequences.getJSONObject(s)
            val steps: JSONArray = sequence.getJSONArray("steps")
            val h = harness()
            h.core.onForeground()
            for (i in 0 until steps.length()) {
                val step = steps.getJSONObject(i)
                if (step.isNull("url")) {
                    h.core.onBackground()
                    h.core.onForeground()
                } else {
                    h.core.captureUtm(step.getString("url"))
                }
                h.core.track(nextEvent())
                val expected = if (step.isNull("expected")) null else step.getString("expected")
                assertEquals("${sequence.getString("name")}[$i]", expected, h.lastEntry().utm())
            }
        }
    }

    // --- Startup and restart ---

    /**
     * SPEC §11.1 item 4: startup only loads — a process start is not a
     * visit (a push or a background job wakes the app without the user). A
     * bare restart carries the stored set from its first event without
     * touching the expiry; the first real foreground edge slides it.
     */
    @Test
    fun aBareRestartCarriesTheStoredUtmAndOnlyTheForegroundSlidesTheExpiry() {
        val store = FakeKeyValueStore()
        val clock = FakeClock()
        harness(store, clock).core.captureUtm(link)
        val capturedExpiry = store.utmExpiry()

        clock.advance(10 * DAY_MS)
        val restarted = harness(store, clock) // startup load: no link, no foreground
        restarted.core.track(nextEvent())
        assertEquals(expectedUtm, restarted.lastEntry().utm())
        assertEquals(capturedExpiry, store.utmExpiry())

        restarted.core.onForeground()
        assertEquals(clock.wall + 30 * DAY_MS, store.utmExpiry())
    }

    /**
     * Background-only launches (a push or a job waking the process every
     * 20 days, never a UI) never refresh the set: it expires 30 days after
     * the capture, as on web without a visit, and the day-40 launch removes it.
     */
    @Test
    fun backgroundOnlyRestartsNeverKeepTheUtmPastThirtyDays() {
        val store = FakeKeyValueStore()
        val clock = FakeClock()
        val t0 = clock.wall
        harness(store, clock).core.captureUtm(link)

        clock.advance(20 * DAY_MS)
        val day20 = harness(store, clock)
        day20.core.track(nextEvent())
        assertEquals(expectedUtm, day20.lastEntry().utm())
        assertEquals(t0 + 30 * DAY_MS, store.utmExpiry())

        clock.advance(20 * DAY_MS)
        val day40 = harness(store, clock)
        assertNoUtmKeys(store)
        day40.core.track(nextEvent())
        assertNull(day40.lastEntry().utm())
    }

    /**
     * Kotlin init-order guard: the startup load is submitted from the
     * constructor and the inline test scheduler runs it *during*
     * construction, so UTM state declared after that submission would be
     * uninitialized when it runs (or re-initialized after it) and the stored
     * value silently lost. The very first event of a fresh core must carry
     * what the store holds.
     */
    @Test
    fun theFirstEventOfAFreshCoreCarriesTheStoredUtm() {
        val store = FakeKeyValueStore()
        val clock = FakeClock()
        UtmStore(store, clock).save(listOf("utm_source" to "flowbiz", "utm_journey" to "16"))

        val h = harness(store, clock)
        h.core.track(nextEvent())
        assertEquals("""{"utm_source":"flowbiz","utm_journey":"16"}""", h.lastEntry().utm())
    }

    @Test
    fun corruptOrExpiredStoredUtmIsRemovedAtStartup() {
        val clock = FakeClock()
        val corrupt = FakeKeyValueStore().apply {
            values[StorageKeys.UTM_DATA] = "{not json"
            values[StorageKeys.UTM_EXPIRES_AT_WALL_MS] = clock.wall + DAY_MS
        }
        val corruptCore = harness(corrupt, clock)
        assertNoUtmKeys(corrupt)
        corruptCore.core.track(nextEvent())
        assertNull(corruptCore.lastEntry().utm())

        val expired = FakeKeyValueStore()
        UtmStore(expired, clock).save(listOf("utm_source" to "flowbiz"))
        clock.advance(30 * DAY_MS)
        val expiredCore = harness(expired, clock)
        assertNoUtmKeys(expired)
        expiredCore.core.track(nextEvent())
        assertNull(expiredCore.lastEntry().utm())
    }

    // --- Sliding expiry ---

    @Test
    fun foregroundAtDay29SlidesTheExpiryToDay59() {
        val h = harness()
        val t0 = h.clock.wall
        h.core.captureUtm(link)
        assertEquals(t0 + 30 * DAY_MS, h.store.utmExpiry())

        h.clock.advance(29 * DAY_MS)
        h.core.onForeground()
        assertEquals(t0 + 59 * DAY_MS, h.store.utmExpiry())

        // Day 58: past the first expiry, still inside the slid one.
        h.clock.advance(29 * DAY_MS)
        h.core.onBackground()
        h.core.onForeground()
        h.core.track(nextEvent())
        assertEquals(expectedUtm, h.lastEntry().utm())
        assertEquals(t0 + 88 * DAY_MS, h.store.utmExpiry())
    }

    /** Core-level boundary: an evaluation at `expires − 1 ms` still reads the set, keeps it and slides it. */
    @Test
    fun oneMillisecondBeforeExpiryTheNextEvaluationKeepsAndSlidesIt() {
        val h = harness()
        h.core.captureUtm(link)
        h.clock.advance(UtmStore.TTL_MS - 1)
        h.core.onForeground()
        assertEquals(h.clock.wall + 30 * DAY_MS, h.store.utmExpiry())
        h.core.track(nextEvent())
        assertEquals(expectedUtm, h.lastEntry().utm())
    }

    @Test
    fun aLinkWithoutUtmsOnAnEmptyStoreLeavesTheContextUnsetAndStoresNothing() {
        val h = harness()
        h.core.captureUtm("https://store.com/produto/1?utm_term=x&utm_flow_params=&ref=home")
        assertNoUtmKeys(h.store)
        h.core.track(nextEvent())
        assertNull(h.lastEntry().utm())
    }

    @Test
    fun aLaterLinkWithoutUtmsKeepsTheSetAndSlidesTheExpiry() {
        val h = harness()
        h.core.captureUtm(link)
        h.clock.advance(5 * DAY_MS)
        h.core.captureUtm("https://store.com/produto/1")
        assertEquals(h.clock.wall + 30 * DAY_MS, h.store.utmExpiry())
        h.core.track(nextEvent())
        assertEquals(expectedUtm, h.lastEntry().utm())
    }

    /**
     * Web page-lifetime semantics: once set, the context rides every event
     * until the next evaluation point — even past the stored expiry — and
     * that evaluation (here a foreground edge) drops it and removes the keys.
     */
    @Test
    fun expiredUtmRidesUntilTheNextEvaluationPointWhichDropsIt() {
        val h = harness()
        h.core.onForeground()
        h.core.captureUtm(link)
        h.clock.advance(30 * DAY_MS) // exactly at expiry: expired on the next read

        h.core.track(nextEvent())
        assertEquals(expectedUtm, h.lastEntry().utm())
        h.scheduler.tickRepeating()
        assertEquals(expectedUtm, h.sentEntries().last { it.getString("event") == "page.ping" }.utm())

        h.core.onBackground()
        h.core.onForeground()
        assertNoUtmKeys(h.store)
        h.core.track(nextEvent())
        assertNull(h.lastEntry().utm())
    }

    // --- Rules that never touch UTM state ---

    @Test
    fun logoutAndAccountEventsKeepTheUtm() {
        val h = harness()
        h.core.captureUtm(link)
        h.core.track(Event.AccountLogin(User(userId = "u-1", email = "u1@example.com")))
        h.core.setPushToken("tok")
        h.core.logout()
        // Logout's own SPEC §10.1 auto-emitted removal carries it too.
        assertEquals(expectedUtm, h.sentEntries().last { it.getString("event") == "push.token.remove" }.utm())
        h.core.track(nextEvent())
        assertEquals(expectedUtm, h.lastEntry().utm())
        assertTrue(h.store.values.containsKey(StorageKeys.UTM_DATA))
    }

    @Test
    fun captureWhileDisabledWritesNothingAndNeverSurfaces() {
        val h = harness()
        h.core.setEnabled(false)
        h.core.captureUtm(link)
        assertNoUtmKeys(h.store)

        h.core.setEnabled(true)
        h.core.track(nextEvent())
        assertNull(h.lastEntry().utm())
    }

    /**
     * SPEC §11.1 item 4 / §12: while disabled, stored UTMs are neither read
     * nor refreshed — startup, foreground, a link and a push open leave a
     * live set exactly as stored, and `utm_data` is never read.
     */
    @Test
    fun aLiveSetIsUntouchedByStartupForegroundAndLinksWhileDisabled() {
        val store = FakeKeyValueStore()
        val clock = FakeClock()
        UtmStore(store, clock).save(listOf("utm_source" to "flowbiz"))
        store.putBoolean(StorageKeys.ENABLED, false)
        val data = store.values[StorageKeys.UTM_DATA]
        val expiry = store.utmExpiry()

        clock.advance(DAY_MS) // a live entry an enabled evaluation would slide
        val h = harness(store, clock)
        h.core.onForeground()
        Flowbiz.handleLink(link, h.core)
        Flowbiz.handlePushOpened(pushWith(link), h.core)
        assertEquals(data, store.values[StorageKeys.UTM_DATA])
        assertEquals(expiry, store.utmExpiry())
        assertFalse(StorageKeys.UTM_DATA in store.reads)
    }

    /**
     * …but an expired set is removed at the next startup, foreground, link
     * or push open while disabled, on its expiry alone: the `utm_data`
     * here is corrupt (a read would discard it as such at startup, while
     * still live) and it is never read — so nothing outlives its 30 days.
     */
    @Test
    fun anExpiredSetIsRemovedAtTheNextEvaluationPointWhileDisabledWithoutReadingIt() {
        val points: List<Pair<String, (CoreHarness) -> Unit>> = listOf(
            "startup" to { h -> harness(h.store, h.clock) },
            "foreground" to { h -> h.core.onForeground() },
            "link" to { h -> Flowbiz.handleLink(link, h.core) },
            "push open" to { h -> Flowbiz.handlePushOpened(pushWith(link), h.core) },
        )
        for ((point, trigger) in points) {
            val clock = FakeClock()
            val store = FakeKeyValueStore().apply {
                values[StorageKeys.UTM_DATA] = "{not json"
                values[StorageKeys.UTM_EXPIRES_AT_WALL_MS] = clock.wall + DAY_MS
                values[StorageKeys.ENABLED] = false
            }
            val h = harness(store, clock)
            assertEquals(point, "{not json", store.values[StorageKeys.UTM_DATA]) // live at startup: kept

            clock.advance(DAY_MS) // exactly at expiry
            trigger(h)
            assertNoUtmKeys(store, point)
            assertFalse(point, StorageKeys.UTM_DATA in store.reads)
        }
    }

    /**
     * Nothing from a disabled period surfaces: the in-memory context of a
     * set captured before the disable is recomputed at the re-enable — here
     * the set expired and was removed while disabled, so the stale value
     * is not sent after a background re-enable either.
     */
    @Test
    fun aContextFromBeforeTheDisableIsNotSurfacedOnceItsSetExpiredWhileDisabled() {
        val h = harness()
        h.core.captureUtm(link)
        h.core.setEnabled(false)
        h.core.captureUtm("https://store.com/?utm_source=while-disabled")
        h.clock.advance(30 * DAY_MS)
        h.core.onForeground() // disabled: removes the expired set only
        assertNoUtmKeys(h.store)
        h.core.onBackground()

        h.core.setEnabled(true) // from the background: a load, which finds nothing
        h.core.track(nextEvent())
        assertNull(h.lastEntry().utm())
    }

    private val pushUtm = """{"utm_source":"flowbiz","utm_medium":"push"}"""

    /** A disabled SDK with a live stored set (saved 5 days ago) and a stored push token, started in the background. */
    private fun disabledHarnessWithStoredUtmAndToken(): CoreHarness {
        val store = FakeKeyValueStore()
        val clock = FakeClock()
        UtmStore(store, clock).save(listOf("utm_source" to "flowbiz", "utm_medium" to "push"))
        store.putBoolean(StorageKeys.ENABLED, false)
        store.putString(StorageKeys.PUSH_TOKEN, "tok")
        clock.advance(5 * DAY_MS)
        return harness(store, clock) // startup while disabled: nothing loaded
    }

    /**
     * SPEC §11.1 item 4: a re-enable while foregrounded is an evaluation —
     * it slides the expiry — and runs *before* the SPEC §10.1 token
     * re-emit, so that event carries the set.
     */
    @Test
    fun reEnableWhileForegroundedSlidesTheExpiryAndTheReEmittedTokenSyncCarriesUtm() {
        val h = disabledHarnessWithStoredUtmAndToken()
        h.core.onForeground()

        h.core.setEnabled(true)
        assertEquals(h.clock.wall + 30 * DAY_MS, h.store.utmExpiry())
        assertEquals(pushUtm, h.sentEntries().last { it.getString("event") == "push.token.sync" }.utm())
        h.core.track(nextEvent())
        assertEquals(pushUtm, h.lastEntry().utm())
    }

    /**
     * A re-enable from the background (a process no user is looking at)
     * only loads: the expiry stays, and the re-emitted token sync still
     * carries the set.
     */
    @Test
    fun reEnableWhileBackgroundedOnlyLoadsAndTheReEmittedTokenSyncCarriesUtm() {
        val h = disabledHarnessWithStoredUtmAndToken()
        val expiry = h.store.utmExpiry()

        h.core.setEnabled(true)
        assertEquals(expiry, h.store.utmExpiry())
        assertEquals(pushUtm, h.sentEntries().last { it.getString("event") == "push.token.sync" }.utm())
        h.core.track(nextEvent())
        assertEquals(pushUtm, h.lastEntry().utm())
    }

    // --- Facade: Flowbiz.handleLink (through its String seam) ---

    /**
     * SPEC §11.1 at the facade: `handleLink` hands every link to the capture
     * whatever the recovery decode returns — a payload for this tenant, no
     * `_mb_cr_`, a foreign `utm_source`, another tenant's link — and the next
     * event carries that link's UTMs. (Pre-initialize silence is pinned by
     * `FlowbizFacadeSmokeTest`.)
     */
    @Test
    fun handleLinkCapturesWhateverTheRecoveryDecodeReturns() {
        fun assertCaptured(case: String, appId: String, url: String, decodes: Boolean, expected: String) {
            val h = CoreHarness(temp.newFolder(), config = FlowbizConfig(appId = appId, baseUri = "https://store.com"))
            assertEquals(case, decodes, Flowbiz.handleLink(url, h.core) != null)
            h.core.track(nextEvent())
            assertEquals(case, expected, h.lastEntry().utm())
        }
        val thirdParty = FixtureSupport.utmExtractVector("third_party_campaign")

        assertCaptured("recovery link for this tenant", "77777", link, decodes = true, expectedUtm)
        assertCaptured("no _mb_cr_", "77777", thirdParty.getString("url"), decodes = false, thirdParty.getString("expected"))
        assertCaptured(
            "foreign utm_source",
            "77777",
            link.replace("utm_source=flowbiz", "utm_source=google"),
            decodes = false,
            """{"utm_source":"google","utm_medium":"email","utm_campaign":"jornadas|cart|carrinho-abandonado",""" +
                """"utm_journey":"16","utm_journey_channel":"email","utm_journey_type":"1"}""",
        )
        assertCaptured("tenant mismatch", "88888", link, decodes = false, expectedUtm)
    }

    // --- Facade: Flowbiz.handlePushOpened (through its seam) ---

    /**
     * SPEC §10.2/§11.1: opening a push is [Flowbiz.handleLink] over its raw
     * `deep_link` — for every web vector, a push carrying the vector's url
     * makes the next event carry exactly the web's `context.utm` (none when
     * the web captures nothing).
     */
    @Test
    fun handlePushOpenedCapturesEveryVectorFromTheDeepLink() {
        val extract = FixtureSupport.utmLinkVectors().getJSONArray("extract")
        for (i in 0 until extract.length()) {
            val vector = extract.getJSONObject(i)
            val h = harness()
            Flowbiz.handlePushOpened(pushWith(vector.getString("url")), h.core)
            h.core.track(nextEvent())
            val expected = if (vector.isNull("expected")) null else vector.getString("expected")
            assertEquals(vector.getString("name"), expected, h.lastEntry().utm())
        }
    }

    /**
     * Links a URL round-trip can alter (on iOS: Foundation folds a rootless
     * custom scheme's fragment into the query, rejects or re-encodes a raw
     * `|`, a non-ASCII host, a bare `%`, `[`/`]` in the query or a second
     * `#`) are read as the raw `deep_link` string, exactly as web reads that
     * text. The same cases as iOS's `FlowbizCoreUtmSuite`, plus an
     * encoded-space campaign with raw `|`; the expected strings come from
     * running the web tag's `url.ts` on the raw links.
     */
    @Test
    fun handlePushOpenedReadsTheRawDeepLinkString() {
        val cases = listOf(
            // A rootless custom scheme with a fragment.
            "myapp:cart?utm_source=flowbiz&utm_medium=push&utm_journey_type=1#promo" to
                """{"utm_source":"flowbiz","utm_medium":"push","utm_journey_type":"1"}""",
            // MessageBuilder writes the campaign's `|` raw.
            link to expectedUtm,
            "https://store.com/carrinho?utm_source=flowbiz&utm_campaign=black%20friday|cart|volte" to
                """{"utm_source":"flowbiz","utm_campaign":"black friday|cart|volte"}""",
            // A raw `|` and a `%20` escape in one value.
            "https://store.com/?utm_campaign=a|b%20c&utm_source=s" to
                """{"utm_source":"s","utm_campaign":"a|b c"}""",
            // IDN hosts.
            "https://lojação.com.br/carrinho?utm_source=flowbiz&utm_medium=push" to
                """{"utm_source":"flowbiz","utm_medium":"push"}""",
            "https://café.com/promo?utm_source=flowbiz&utm_campaign=a|b" to
                """{"utm_source":"flowbiz","utm_campaign":"a|b"}""",
            // A bare `%`, with a valid escape elsewhere in the link.
            "https://store.com/?utm_campaign=Black%20Friday&utm_medium=100%" to
                """{"utm_medium":"100%","utm_campaign":"Black Friday"}""",
            // `[` / `]` outside the host, and an IPv6 literal host.
            "https://store.com/?utm_campaign=promo[1]&utm_medium=e%20mail" to
                """{"utm_medium":"e mail","utm_campaign":"promo[1]"}""",
            "https://[::1]:8080/p?utm_source=a|b&utm_medium=e%20mail" to
                """{"utm_source":"a|b","utm_medium":"e mail"}""",
            // A second `#`, and a hash route with a `#` after its query
            // (MessageBuilder's fragment shape): web cuts the query there.
            "https://store.com/?utm_campaign=a|b&utm_medium=e%20mail#top#x" to
                """{"utm_medium":"e mail","utm_campaign":"a|b"}""",
            "https://store.com/#/cart?utm_source=a|b&utm_medium=e%20mail#/cart" to
                """{"utm_source":"a|b","utm_medium":"e mail"}""",
            // Web sends a value it cannot decode raw, valid escapes included.
            "https://store.com/?utm_campaign=Black%20Friday 50%&utm_medium=e%20mail" to
                """{"utm_medium":"e mail","utm_campaign":"Black%20Friday 50%"}""",
            "https://store.com/?utm_campaign=50%%20off&utm_source=s" to
                """{"utm_source":"s","utm_campaign":"50%%20off"}""",
            "https://store.com/?utm_campaign=a|b%C3&utm_source=%E2%82%AC" to
                """{"utm_source":"€","utm_campaign":"a|b%C3"}""",
        )
        for ((raw, expected) in cases) {
            assertEquals("port vs web: $raw", expected, UtmLinkParser.render(UtmLinkParser.extract(raw)))
            val push = pushWith(raw)
            assertEquals(raw, push.deepLinkString)
            val h = harness()
            Flowbiz.handlePushOpened(push, h.core)
            h.core.track(nextEvent())
            assertEquals(raw, expected, h.lastEntry().utm())
        }
    }

    /**
     * The `_mb_cr_` hash of the `basic` recovery vector
     * (`shared/recovery-links/vectors.json`): cart-abc-001 for appId 77777.
     */
    private val basicRecoveryHash =
        "eyJ0IjoiNzc3NzciLCJ1IjoidXNlci0xMjMiLCJjIjoiY2FydC1hYmMtMDAxIiwiaXRzIjpbWyIyIiwiUDEwMCIsIlNLVS0xMDAtUCJdLFsiMSIsIlAyMDAiLCJTS1UtMjAwLU0iXV19"

    /**
     * The return value is [Flowbiz.handleLink]'s over the raw link:
     * tenant-checked — another tenant's push returns null where the pure
     * [FlowbizPush.recoveryPayload] still decodes — while the UTMs are
     * captured either way. Links a URL round-trip would alter decode the
     * same way as on iOS: a rootless link keeps its recovery, and a hash
     * route with a later `#` stays null.
     */
    @Test
    fun handlePushOpenedReturnsTheTenantCheckedPayloadAndCapturesEitherWay() {
        data class Case(val label: String, val appId: String, val link: String, val cartId: String?, val utm: String)
        val cases = listOf(
            Case("this tenant", "77777", link, "cart-abc-001", expectedUtm),
            Case("tenant mismatch", "88888", link, null, expectedUtm),
            Case(
                "rootless custom scheme", "77777", "myapp:cart?utm_source=flowbiz&_mb_cr_=$basicRecoveryHash#promo",
                "cart-abc-001", """{"utm_source":"flowbiz"}""",
            ),
            Case(
                "hash route with a later #", "77777",
                "https://store.com/#/cart?_mb_cr_=$basicRecoveryHash&utm_source=flowbiz#/cart",
                null, """{"utm_source":"flowbiz"}""",
            ),
        )
        for (case in cases) {
            val config = FlowbizConfig(appId = case.appId, baseUri = "https://store.com")
            val push = pushWith(case.link)
            val h = CoreHarness(temp.newFolder(), config = config)
            val opened = Flowbiz.handlePushOpened(push, h.core)
            assertEquals(case.label, case.cartId, opened?.cartId)
            if (opened != null) assertEquals(case.label, push.recoveryPayload, opened)
            assertEquals(case.label, Flowbiz.handleLink(case.link, CoreHarness(temp.newFolder(), config = config).core), opened)
            assertEquals("${case.label}: recoveryPayload", RecoveryLinkParser.parse(case.link), push.recoveryPayload)
            h.core.track(nextEvent())
            assertEquals(case.label, case.utm, h.lastEntry().utm())
        }
        // Pure recoveryPayload: no tenant check, so the mismatch decodes.
        assertEquals("cart-abc-001", pushWith(link).recoveryPayload?.cartId)
    }

    /**
     * The public [Flowbiz.handlePushOpened] hands the live singleton core to
     * its seam. [Flowbiz.initialize] needs a real `Context`, so a harness
     * core is installed in the private `core` field by reflection for this
     * test only, and cleared in `finally` (every other facade test runs
     * pre-initialize). The tenant check and the capture both prove that the
     * installed core was used, since a null core would decode another
     * tenant's link and capture nothing.
     */
    @Test
    fun thePublicHandlePushOpenedUsesTheInitializedCore() {
        val field = Flowbiz::class.java.getDeclaredField("core").apply { isAccessible = true }
        val push = pushWith(link)
        val otherTenant = CoreHarness(temp.newFolder(), config = FlowbizConfig(appId = "88888", baseUri = "https://store.com"))
        val h = harness()
        check(field.get(null) == null) { "a core is already installed" }
        try {
            field.set(null, otherTenant.core)
            assertNull(Flowbiz.handlePushOpened(push))
            field.set(null, h.core)
            assertEquals("cart-abc-001", Flowbiz.handlePushOpened(push)?.cartId)
        } finally {
            field.set(null, null)
        }
        otherTenant.core.track(nextEvent())
        assertEquals(expectedUtm, otherTenant.lastEntry().utm())
        h.core.track(nextEvent())
        assertEquals(expectedUtm, h.lastEntry().utm())
    }

    /** No push, or a push without `deep_link`: null, and no evaluation runs (the stored expiry does not slide). */
    @Test
    fun handlePushOpenedWithoutADeepLinkReturnsNullAndCapturesNothing() {
        val h = harness()
        h.core.captureUtm(link)
        h.clock.advance(DAY_MS)
        val expiry = h.store.utmExpiry()

        assertNull(Flowbiz.handlePushOpened(null, h.core))
        assertNull(Flowbiz.handlePushOpened(pushWith(null), h.core))
        assertEquals(expiry, h.store.utmExpiry())
    }

    // --- Threading ---

    /**
     * SPEC §3: UTM loads and evaluations run on the scheduler, never on the
     * caller's (typically main) thread — the store is SharedPreferences I/O
     * and [FlowbizCore]'s UTM state is scheduler-confined. With a scheduler
     * that holds its tasks, neither the startup load nor a capture reads or
     * writes the UTM keys until the scheduler runs them. (The inline
     * scheduler of the other tests cannot tell the two apart.)
     */
    @Test
    fun startupAndCaptureRunOnTheSchedulerNotOnTheCaller() {
        val store = FakeKeyValueStore()
        val clock = FakeClock()
        UtmStore(store, clock).save(listOf("utm_source" to "flowbiz"))
        val data = store.values[StorageKeys.UTM_DATA]
        val expiry = store.utmExpiry()
        clock.advance(DAY_MS) // a live entry the capture will slide

        val scheduler = FakeTaskScheduler(inline = false)
        val h = CoreHarness(temp.newFolder(), store = store, clock = clock, scheduler = scheduler)
        h.core.captureUtm(link)
        assertFalse(StorageKeys.UTM_DATA in store.reads)
        assertFalse(StorageKeys.UTM_EXPIRES_AT_WALL_MS in store.reads)
        assertEquals(data, store.values[StorageKeys.UTM_DATA])
        assertEquals(expiry, store.utmExpiry())

        scheduler.runPending()
        assertEquals(clock.wall + 30 * DAY_MS, store.utmExpiry())
        h.core.track(nextEvent())
        scheduler.runPending()
        assertEquals(expectedUtm, h.lastEntry().utm())
    }

    // --- Ordering on the real executor ---

    /**
     * SPEC §11.1 item 5: `handleLink(url)` then `track(…)` from the same
     * thread always carries the link's UTMs — both hop onto the one serial
     * executor in call order (FIFO), on the production scheduler.
     */
    @Test(timeout = 15_000)
    fun captureThenTrackFromTheCallerThreadIsOrderedOnTheRealExecutor() {
        val executor = Executors.newSingleThreadScheduledExecutor()
        try {
            val queueFile = File(temp.newFolder(), "queue.jsonl")
            val sent = CountDownLatch(1)
            val sender = FakeHttpSender().apply { onSend = { sent.countDown() } }
            val core = FlowbizCore(
                config = FlowbizConfig(appId = "77777", baseUri = "https://store.com"),
                store = FakeKeyValueStore(),
                queueFactory = { EventQueue(queueFile) },
                sender = sender,
                scheduler = ExecutorTaskScheduler(executor),
                clock = FakeClock(),
                deviceContext = FakeDeviceContext(),
                reachability = FakeReachability(),
            )
            core.captureUtm(link)
            core.track(Event.PageView(path = "/carrinho/recuperar", title = "Recuperação"))

            // The track task queues its flush drain; wait for that send, then
            // serialize behind it to read settled state.
            assertTrue(sent.await(10, TimeUnit.SECONDS))
            val bodies = executor.submit<List<String>> { sender.bodies.toList() }.get()
            val entry = JSONObject(bodies.single()).getJSONArray("data").getJSONObject(0)
            assertEquals("page.view", entry.getString("event"))
            assertEquals(expectedUtm, entry.utm())
        } finally {
            executor.shutdownNow()
        }
    }
}
