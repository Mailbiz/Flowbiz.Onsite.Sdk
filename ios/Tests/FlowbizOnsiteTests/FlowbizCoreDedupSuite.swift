#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct FlowbizCoreDedupSuite {

    // An event with data, which web also dedups (EventsState); page.view never is.
    private func coupon(_ code: String) -> Event { .cartSetCoupon(cartId: "c1", coupon: code) }

    @Test func pageViewIsNeverDeduped() throws {
        let h = CoreHarness()
        h.core.track(.pageView(path: "home"))
        h.core.track(.pageView(path: "home"))
        #expect(try h.sentEntries().count == 2)
    }

    @Test func identicalPayloadWithinWindowIsSuppressed() throws {
        let h = CoreHarness()
        h.core.track(coupon("A"))
        h.clock.advance(5 * minuteMs)
        h.core.track(coupon("A"))
        #expect(try h.sentEntries().count == 1)
    }

    @Test func identicalPayloadAfterWindowSendsAgain() throws {
        let h = CoreHarness()
        h.core.track(coupon("A"))
        h.clock.advance(DedupStore.windowMillis)
        h.core.track(coupon("A"))
        #expect(try h.sentEntries().count == 2)
    }

    @Test func renewOnDuplicateSemanticsPinned() throws {
        // t=30 is past a fixed 20-min window from the send but inside the one the t=15 duplicate renewed.
        let h = CoreHarness()
        h.core.track(coupon("A"))
        h.clock.advance(15 * minuteMs)
        h.core.track(coupon("A"))
        h.clock.advance(15 * minuteMs)
        h.core.track(coupon("A"))
        #expect(try h.sentEntries().count == 1)

        h.clock.advance(20 * minuteMs)
        h.core.track(coupon("A"))
        #expect(try h.sentEntries().count == 2)
    }

    @Test func differentPayloadForSameEventSends() throws {
        let h = CoreHarness()
        h.core.track(coupon("A"))
        h.core.track(coupon("B"))
        #expect(try h.sentEntries().count == 2)
    }

    @Test func differentWireNamesDedupIndependently() throws {
        let user = User(userId: "98412", email: "maria.oliveira@gmail.com")
        let h = CoreHarness()
        h.core.track(.accountLogin(user: user))
        h.core.track(.accountSync(user: user))
        #expect(try h.sentEntries().count == 2)
    }

    @Test func emptyCartSyncIsNeverSpeciallySuppressed() throws {
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
        first.core.track(coupon("A"))
        #expect(try first.sentEntries().count == 1)

        clock.advance(5 * minuteMs)
        let second = CoreHarness(store: store, clock: clock)
        second.core.track(coupon("A"))
        #expect(try second.sentEntries().count == 0)

        clock.advance(DedupStore.windowMillis)
        second.core.track(coupon("A"))
        #expect(try second.sentEntries().count == 1)
    }

    @Test func dedupStoresDigestNotPayload() throws {
        let h = CoreHarness()
        h.core.track(coupon("A"))
        let stored = try #require(h.store[DedupStore.digestKeyPrefix + "cart.setcoupon"] as? String)
        let dataJSON = try EventSerializer.dataJSONString(coupon("A"), baseUri: "https://store.com")
        #expect(stored == DedupStore.sha256Hex(dataJSON))
        #expect(stored.count == 64)
    }

    @Test func backwardsClockJumpDoesNotSuppressForever() throws {
        let h = CoreHarness()
        h.core.track(coupon("A"))
        h.clock.wall -= 60 * minuteMs
        h.core.track(coupon("A"))
        #expect(try h.sentEntries().count == 2)
    }

    @Test func suppressedDuplicateStillTouchesSession() throws {
        let h = CoreHarness()
        h.core.track(coupon("A"))
        let first = object(try h.lastEntry(), "identity")
        for _ in 0..<3 {
            h.clock.advance(15 * minuteMs)
            h.core.track(coupon("A"))
        }
        h.clock.advance(20 * minuteMs)
        h.core.track(coupon("A"))
        let last = object(try h.lastEntry(), "identity")
        #expect(try h.sentEntries().count == 2)
        #expect(last["session_id"] as? String == first["session_id"] as? String)
    }
}
#endif
