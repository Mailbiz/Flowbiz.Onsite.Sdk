#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct FlowbizCoreSuite {

    private let user = User(userId: "98412", email: "maria.oliveira@gmail.com")

    @Test func trackedEnvelopeCarriesIdentitySessionContextAndData() throws {
        let h = CoreHarness()
        h.core.track(.pageView(path: "home"))

        let entry = try h.lastEntry()
        #expect(entry["event"] as? String == "page.view")
        #expect(entry["app_id"] as? String == "77777")
        #expect(entry["platform"] as? String == "ios")
        #expect(entry["v_tracker"] as? String == "flowbiz-ios-sdk")
        #expect(entry["v_version"] as? String == "ios-\(SDKVersion.current)")
        #expect(isUUIDShaped(entry["hash"]))

        let identity = object(entry, "identity")
        #expect(identity["user_id"] == nil)
        #expect(isUUIDShaped(identity["anonymous_id"]))
        #expect(isUUIDShaped(identity["session_id"]))
        #expect(identity["visit_count"] as? Int == 1)

        let context = object(entry, "context")
        #expect(context["platform"] as? String == "ios")
        #expect(context["language"] as? String == "pt-BR")
        #expect(context["screen"] as? String == "1170x2532")
        #expect(context["vendor"] as? String == "flowbiz-ios-sdk")
        #expect(context["onsite_version"] as? String == SDKVersion.current)
        #expect(context["url"] as? String == "https://store.com/home")

        let timings = object(entry, "timings")
        let expectedIso = EnvelopeBuilder.isoMillis(h.clock.wall)
        #expect(timings["created_at"] as? String == expectedIso)
        #expect(timings["sent_at"] as? String == expectedIso)
        #expect(timings["timezone"] as? String == "-03:00")

        #expect(entry["data"] as? String == (try EventSerializer.dataJSONString(.pageView(path: "home"), baseUri: "https://store.com")))
    }

    @Test func trackedEnvelopeDataMatchesSharedFixture() throws {
        let h = CoreHarness()
        let url = FixtureSupport.fixturesDirectory().appendingPathComponent("cart_sync_full.json")
        let fixture = try FixtureSupport.loadFixture(url)
        let event = try FixtureSupport.buildEvent(
            fixture["event"] as? String ?? "",
            input: fixture["input"] as? [String: Any] ?? [:]
        )
        h.core.track(event)

        let expected = fixture["expected"] as? [String: Any] ?? [:]
        let entry = try h.lastEntry()
        #expect(entry["event"] as? String == expected["wire_event"] as? String)
        #expect(entry["data"] as? String == expected["data_canonical"] as? String)
    }

    @Test func contextUrlAbsentBeforeAnyPageViewThenPresentOnEveryEvent() throws {
        let h = CoreHarness()
        h.core.track(.cartSetCoupon(cartId: "c-1", coupon: "X"))
        #expect(object(try h.lastEntry(), "context")["url"] == nil)

        h.core.track(.pageView(path: "/checkout", title: "Checkout"))
        #expect(object(try h.lastEntry(), "context")["url"] as? String == "https://store.com/checkout")

        h.core.track(.cartSetCoupon(cartId: "c-1", coupon: "Y"))
        #expect(object(try h.lastEntry(), "context")["url"] as? String == "https://store.com/checkout")

        h.core.track(.pageView())
        #expect(object(try h.lastEntry(), "context")["url"] as? String == "https://store.com/checkout")
    }

    @Test func everyEventCarriesBaseUriAndRecoveryUrlFromConfig() throws {
        let h = CoreHarness(config: FlowbizConfig(
            appId: "77777", baseUri: "https://store.com", recoveryUrl: "https://store.com/carrinho"
        ))
        h.core.track(.cartSetCoupon(cartId: "c-1", coupon: "X"))
        let context = object(try h.lastEntry(), "context")
        #expect(context["baseuri"] as? String == "https://store.com")
        #expect(context["recoveryUrl"] as? String == "https://store.com/carrinho")
    }

    @Test func recoveryUrlAbsentWhenNotConfigured() throws {
        let h = CoreHarness()
        h.core.track(.cartSetCoupon(cartId: "c-1", coupon: "X"))
        let context = object(try h.lastEntry(), "context")
        #expect(context["baseuri"] as? String == "https://store.com")
        #expect(context["recoveryUrl"] == nil)
    }

    @Test func productUrlsAreResolvedAgainstConfigBaseUri() throws {
        let h = CoreHarness()
        h.core.track(.productView(product: Product(
            productId: "P1", url: "/p1", variants: [ProductVariant(sku: "S1", price: 1, imageUrl: "//cdn.store.com/p1.jpg")]
        )))
        let data = try #require(try h.lastEntry()["data"] as? String)
        #expect(data.contains(#""url":"https://store.com/p1""#))
        #expect(data.contains(#""image_url":"https://cdn.store.com/p1.jpg""#))
    }

    @Test func trackedEventIsQueuedThenDrainedBySuccessfulFlush() throws {
        let h = CoreHarness()
        h.core.track(.pageView(path: "home"))
        #expect(h.queue.size == 0)
        #expect(h.sender.bodies.count == 1)
    }

    @Test func accountLoginSetsUserIdOnItselfAndSubsequentEvents() throws {
        let h = CoreHarness()
        h.core.track(.accountLogin(user: user))
        #expect(object(try h.lastEntry(), "identity")["user_id"] as? String == "98412")

        h.core.track(.pageView(path: "home"))
        #expect(object(try h.lastEntry(), "identity")["user_id"] as? String == "98412")
        #expect(h.store[StorageKeys.userId] as? String == "98412")
        #expect(h.store[StorageKeys.email] as? String == "maria.oliveira@gmail.com")
    }

    @Test func accountSyncAlsoStoresIdentity() throws {
        let h = CoreHarness()
        h.core.track(.accountSync(user: user))
        #expect(object(try h.lastEntry(), "identity")["user_id"] as? String == "98412")
    }

    @Test func logoutClearsUserRotatesSessionAndClearsPushToken() throws {
        let h = CoreHarness()
        h.store[StorageKeys.pushToken] = "apns-token-1"
        h.core.track(.accountLogin(user: user))
        let before = object(try h.lastEntry(), "identity")

        h.core.logout()
        h.core.track(.pageView(path: "home"))
        let after = object(try h.lastEntry(), "identity")

        #expect(after["user_id"] == nil)
        #expect(after["session_id"] as? String != before["session_id"] as? String)
        #expect(after["visit_count"] as? Int == (before["visit_count"] as? Int ?? 0) + 1)
        #expect(after["anonymous_id"] as? String == before["anonymous_id"] as? String)
        #expect(h.store[StorageKeys.pushToken] == nil)
        #expect(h.store[StorageKeys.userId] == nil)
        #expect(h.store[StorageKeys.email] == nil)
    }

    @Test func everyTrackSlidesTheSessionWindow() throws {
        let h = CoreHarness()
        h.core.track(.pageView(path: "a"))
        let first = object(try h.lastEntry(), "identity")

        for index in 0..<3 {
            h.clock.advance(20 * minuteMs)
            h.core.track(.pageView(path: "screen-\(index)"))
        }
        let last = object(try h.lastEntry(), "identity")
        #expect(last["session_id"] as? String == first["session_id"] as? String)
        #expect(last["visit_count"] as? Int == first["visit_count"] as? Int)
    }

    @Test func trackAfterThirtyIdleMinutesRotatesSession() throws {
        let h = CoreHarness()
        h.core.track(.pageView(path: "a"))
        let first = object(try h.lastEntry(), "identity")

        h.clock.advance(31 * minuteMs)
        h.core.track(.pageView(path: "b"))
        let second = object(try h.lastEntry(), "identity")

        #expect(second["session_id"] as? String != first["session_id"] as? String)
        #expect(second["visit_count"] as? Int == (first["visit_count"] as? Int ?? 0) + 1)
    }

    @Test(arguments: [
        (0, "+00:00"),
        (-180, "-03:00"),
        (330, "+05:30"),
        (-570, "-09:30"),
        (345, "+05:45"),
        (840, "+14:00"),
    ])
    func timezoneOffsetsRenderAsSignedHoursMinutes(minutes: Int, expected: String) throws {
        let h = CoreHarness()
        h.offset.value = minutes
        h.core.track(.pageView(path: "screen-\(minutes)"))
        #expect(object(try h.lastEntry(), "timings")["timezone"] as? String == expected)
        #expect(FlowbizCore.formatTimezoneOffset(minutes: minutes) == expected)
    }

    @Test func nanPriceEventIsDroppedAndNextEventIsFine() throws {
        let h = CoreHarness()
        let poison = Event.productView(
            product: Product(productId: "P1", variants: [ProductVariant(sku: "S1", price: .nan)])
        )
        h.core.track(poison)
        #expect(h.sender.bodies.isEmpty)
        #expect(h.queue.size == 0)

        h.core.track(.pageView(path: "recovered"))
        #expect(h.sender.bodies.count == 1)
        #expect(try h.lastEntry()["event"] as? String == "page.view")
    }

    @Test func explicitFlushDrainsARetriableBacklog() throws {
        let h = CoreHarness()
        h.sender.results = [.retriableError]
        h.core.track(.pageView(path: "home"))
        #expect(h.queue.size == 1)

        h.core.flush()
        #expect(h.queue.size == 0)
        #expect(h.sender.bodies.count == 2)
    }

    @Test func networkRestorationDrainsBacklogWhenEnabled() throws {
        let h = CoreHarness()
        #expect(h.reachability.started)
        h.sender.results = [.retriableError]
        h.core.track(.pageView(path: "home"))
        #expect(h.queue.size == 1)

        h.reachability.callback?()
        #expect(h.queue.size == 0)
    }
}
#endif
