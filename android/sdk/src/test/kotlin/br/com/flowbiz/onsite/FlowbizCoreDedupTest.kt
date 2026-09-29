package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FlowbizCoreDedupTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun harness() = CoreHarness(temp.newFolder())

    @Test
    fun identicalPayloadWithinWindowIsSuppressed() {
        val h = harness()
        h.core.track(Event.PageView("home"))
        h.clock.advance(5 * MINUTE_MS)
        h.core.track(Event.PageView("home"))
        assertEquals(1, h.sentEntries().size)
    }

    @Test
    fun identicalPayloadAfterWindowSendsAgain() {
        val h = harness()
        h.core.track(Event.PageView("home"))
        h.clock.advance(DedupStore.WINDOW_MS) // boundary: exactly 20 min → expired
        h.core.track(Event.PageView("home"))
        assertEquals(2, h.sentEntries().size)
    }

    @Test
    fun renewOnDuplicateSemanticsPinned() {
        // Web EventsState parity: a suppressed duplicate renews the window, so
        // the t=30 duplicate is still suppressed (15 min after the last one).
        val h = harness()
        h.core.track(Event.PageView("home"))
        h.clock.advance(15 * MINUTE_MS)
        h.core.track(Event.PageView("home"))
        h.clock.advance(15 * MINUTE_MS)
        h.core.track(Event.PageView("home"))
        assertEquals(1, h.sentEntries().size)

        h.clock.advance(20 * MINUTE_MS)
        h.core.track(Event.PageView("home"))
        assertEquals(2, h.sentEntries().size)
    }

    @Test
    fun differentPayloadForSameEventSends() {
        val h = harness()
        h.core.track(Event.PageView("home"))
        h.core.track(Event.PageView("cart"))
        assertEquals(2, h.sentEntries().size)
    }

    @Test
    fun differentWireNamesDedupIndependently() {
        val user = User(userId = "98412", email = "maria.oliveira@gmail.com")
        val h = harness()
        h.core.track(Event.AccountLogin(user))
        h.core.track(Event.AccountSync(user))
        assertEquals(2, h.sentEntries().size)
    }

    @Test
    fun emptyCartSyncIsNeverSpeciallySuppressed() {
        // Emptying the cart is a signal: no empty-cart suppression.
        val emptyCart = Event.CartSync(
            Cart(cartId = "c1", subtotal = 0.0, total = 0.0, freight = 0.0, tax = 0.0, discounts = 0.0)
        )
        val h = harness()
        h.core.track(emptyCart)
        assertEquals(1, h.sentEntries().size)
    }

    @Test
    fun dedupStateSurvivesCoreRecreation() {
        val dir = temp.newFolder()
        val store = FakeKeyValueStore()
        val clock = FakeClock()
        val first = CoreHarness(dir, store = store, clock = clock)
        first.core.track(Event.PageView("home"))
        assertEquals(1, first.sentEntries().size)

        clock.advance(5 * MINUTE_MS)
        val second = CoreHarness(temp.newFolder(), store = store, clock = clock)
        second.core.track(Event.PageView("home"))
        assertEquals(0, second.sentEntries().size)

        clock.advance(DedupStore.WINDOW_MS)
        second.core.track(Event.PageView("home"))
        assertEquals(1, second.sentEntries().size)
    }

    @Test
    fun dedupStoresDigestNotPayload() {
        val h = harness()
        h.core.track(Event.PageView("home"))
        val stored = h.store.values[DedupStore.DIGEST_KEY_PREFIX + "page.view"] as String
        val dataJson = EventSerializer.dataJson(Event.PageView("home"), "https://store.com")
        assertEquals(DedupStore.sha256Hex(dataJson), stored)
        assertFalse(stored.contains("home"))
        assertEquals(64, stored.length)
    }

    @Test
    fun backwardsClockJumpDoesNotSuppressForever() {
        val h = harness()
        h.core.track(Event.PageView("home"))
        h.clock.wall -= 60 * MINUTE_MS
        h.core.track(Event.PageView("home"))
        assertEquals(2, h.sentEntries().size)
    }

    @Test
    fun suppressedDuplicateStillTouchesSession() {
        // Dedup drops the wire event, but the user activity is real.
        val h = harness()
        h.core.track(Event.PageView("home"))
        val first = h.lastEntry().getJSONObject("identity")
        repeat(3) {
            h.clock.advance(15 * MINUTE_MS)
            h.core.track(Event.PageView("home"))
        }
        h.clock.advance(20 * MINUTE_MS) // dedup expired; 20 < 30 session idle
        h.core.track(Event.PageView("home"))
        val last = h.lastEntry().getJSONObject("identity")
        assertTrue(h.sentEntries().size == 2)
        assertEquals(first.getString("session_id"), last.getString("session_id"))
    }
}
