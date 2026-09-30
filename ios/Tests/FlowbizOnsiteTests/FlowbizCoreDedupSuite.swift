#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct FlowbizCoreDedupSuite {

    @Test func identicalPayloadWithinWindowIsSuppressed() throws {
        let h = CoreHarness()
        h.core.track(.pageView(path: "home"))
        h.clock.advance(5 * minuteMs)
        h.core.track(.pageView(path: "home"))
        #expect(try h.sentEntries().count == 1)
    }

    @Test func identicalPayloadAfterWindowSendsAgain() throws {
        let h = CoreHarness()
        h.core.track(.pageView(path: "home"))
        h.clock.advance(DedupStore.windowMillis)
        h.core.track(.pageView(path: "home"))
        #expect(try h.sentEntries().count == 2)
    }

    @Test func renewOnDuplicateSemanticsPinned() throws {
        // t=30 is past a fixed 20-min window from the send but inside the one the t=15 duplicate renewed.
        let h = CoreHarness()
        h.core.track(.pageView(path: "home"))
        h.clock.advance(15 * minuteMs)
        h.core.track(.pageView(path: "home"))
        h.clock.advance(15 * minuteMs)
        h.core.track(.pageView(path: "home"))
        #expect(try h.sentEntries().count == 1)

        h.clock.advance(20 * minuteMs)
        h.core.track(.pageView(path: "home"))
        #expect(try h.sentEntries().count == 2)
    }

    @Test func differentPayloadForSameEventSends() throws {
        let h = CoreHarness()
        h.core.track(.pageView(path: "home"))
        h.core.track(.pageView(path: "cart"))
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
        first.core.track(.pageView(path: "home"))
        #expect(try first.sentEntries().count == 1)

        clock.advance(5 * minuteMs)
        let second = CoreHarness(store: store, clock: clock)
        second.core.track(.pageView(path: "home"))
        #expect(try second.sentEntries().count == 0)

        clock.advance(DedupStore.windowMillis)
        second.core.track(.pageView(path: "home"))
        #expect(try second.sentEntries().count == 1)
    }

    @Test func dedupStoresDigestNotPayload() throws {
        let h = CoreHarness()
        h.core.track(.pageView(path: "home"))
        let stored = try #require(h.store[DedupStore.digestKeyPrefix + "page.view"] as? String)
        let dataJSON = try EventSerializer.dataJSONString(.pageView(path: "home"), baseUri: "https://store.com")
        #expect(stored == DedupStore.sha256Hex(dataJSON))
        #expect(!stored.contains("home"))
        #expect(stored.count == 64)
    }

    @Test func backwardsClockJumpDoesNotSuppressForever() throws {
        let h = CoreHarness()
        h.core.track(.pageView(path: "home"))
        h.clock.wall -= 60 * minuteMs
        h.core.track(.pageView(path: "home"))
        #expect(try h.sentEntries().count == 2)
    }

    @Test func suppressedDuplicateStillTouchesSession() throws {
        let h = CoreHarness()
        h.core.track(.pageView(path: "home"))
        let first = object(try h.lastEntry(), "identity")
        for _ in 0..<3 {
            h.clock.advance(15 * minuteMs)
            h.core.track(.pageView(path: "home"))
        }
        h.clock.advance(20 * minuteMs)
        h.core.track(.pageView(path: "home"))
        let last = object(try h.lastEntry(), "identity")
        #expect(try h.sentEntries().count == 2)
        #expect(last["session_id"] as? String == first["session_id"] as? String)
    }
}
#endif
