// SPEC §7 dedup through the full `FlowbizCore` pipeline: 20-min window,
// renew-on-duplicate semantics (pinned), payload sensitivity, per-wire-name
// isolation, persistence across core recreation.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct FlowbizCoreDedupSuite {

    @Test func identicalPayloadWithinWindowIsSuppressed() throws {
        let h = CoreHarness()
        h.core.track(.pageView(screenName: "home"))
        h.clock.advance(5 * minuteMs)
        h.core.track(.pageView(screenName: "home"))
        #expect(try h.sentEntries().count == 1)
    }

    @Test func identicalPayloadAfterWindowSendsAgain() throws {
        let h = CoreHarness()
        h.core.track(.pageView(screenName: "home"))
        h.clock.advance(DedupStore.windowMillis) // boundary: exactly 20 min → expired
        h.core.track(.pageView(screenName: "home"))
        #expect(try h.sentEntries().count == 2)
    }

    @Test func renewOnDuplicateSemanticsPinned() throws {
        // Web EventsState parity: a suppressed duplicate RENEWS the window.
        // t=0 send; t=15 duplicate (suppressed, renews); t=30 duplicate —
        // a fixed window from the send would let this through (30 > 20);
        // the renewed window (15 min since last duplicate) suppresses it.
        let h = CoreHarness()
        h.core.track(.pageView(screenName: "home"))
        h.clock.advance(15 * minuteMs)
        h.core.track(.pageView(screenName: "home"))
        h.clock.advance(15 * minuteMs)
        h.core.track(.pageView(screenName: "home"))
        #expect(try h.sentEntries().count == 1)

        // After a quiet 20 minutes it sends again.
        h.clock.advance(20 * minuteMs)
        h.core.track(.pageView(screenName: "home"))
        #expect(try h.sentEntries().count == 2)
    }

    @Test func differentPayloadForSameEventSends() throws {
        let h = CoreHarness()
        h.core.track(.pageView(screenName: "home"))
        h.core.track(.pageView(screenName: "cart"))
        #expect(try h.sentEntries().count == 2)
    }

    @Test func differentWireNamesDedupIndependently() throws {
        let user = User(userId: "98412", email: "maria.oliveira@gmail.com")
        let h = CoreHarness()
        // Identical data payloads, distinct wire names → both send.
        h.core.track(.accountLogin(user: user))
        h.core.track(.accountSync(user: user))
        #expect(try h.sentEntries().count == 2)
    }

    @Test func emptyCartSyncIsNeverSpeciallySuppressed() throws {
        // SPEC §7: no empty-cart suppression — but normal dedup still applies.
        let emptyCart = Event.cartSync(
            cart: Cart(cartId: "c1", subtotal: 0, total: 0, freight: 0, tax: 0, discounts: 0)
        )
        let h = CoreHarness()
        h.core.track(emptyCart)
        #expect(try h.sentEntries().count == 1)
    }

    @Test func dedupStateSurvivesCoreRecreation() throws {
        let store = FakeKeyValueStore()
        let clock = FakeClock()
        let first = CoreHarness(store: store, clock: clock)
        first.core.track(.pageView(screenName: "home"))
        #expect(try first.sentEntries().count == 1)

        // "Process restart": new core over the same persisted store.
        clock.advance(5 * minuteMs)
        let second = CoreHarness(store: store, clock: clock)
        second.core.track(.pageView(screenName: "home"))
        #expect(try second.sentEntries().count == 0) // still within the window

        clock.advance(DedupStore.windowMillis)
        second.core.track(.pageView(screenName: "home"))
        #expect(try second.sentEntries().count == 1)
    }

    @Test func dedupStoresDigestNotPayload() throws {
        let h = CoreHarness()
        h.core.track(.pageView(screenName: "home"))
        let stored = try #require(h.store[DedupStore.digestKeyPrefix + "page.view"] as? String)
        let dataJSON = try EventSerializer.dataJSONString(.pageView(screenName: "home"))
        #expect(stored == DedupStore.sha256Hex(dataJSON))
        #expect(!stored.contains("home")) // digest, not the raw payload
        #expect(stored.count == 64)
    }

    @Test func backwardsClockJumpDoesNotSuppressForever() throws {
        let h = CoreHarness()
        h.core.track(.pageView(screenName: "home"))
        h.clock.wall -= 60 * minuteMs // clock rolled back past the anchor
        h.core.track(.pageView(screenName: "home"))
        #expect(try h.sentEntries().count == 2)
    }

    @Test func suppressedDuplicateStillTouchesSession() throws {
        // Dedup drops the wire event, but the user activity is real: the
        // session window must still slide (SPEC §6: every tracked event).
        let h = CoreHarness()
        h.core.track(.pageView(screenName: "home"))
        let first = object(try h.lastEntry(), "identity")
        for _ in 0..<3 {
            h.clock.advance(15 * minuteMs)
            h.core.track(.pageView(screenName: "home")) // suppressed, slides window
        }
        h.clock.advance(20 * minuteMs) // dedup expired; 20 < 30 session idle
        h.core.track(.pageView(screenName: "home"))
        let last = object(try h.lastEntry(), "identity")
        #expect(try h.sentEntries().count == 2)
        #expect(last["session_id"] as? String == first["session_id"] as? String)
    }
}
#endif
