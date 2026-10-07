#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite final class FlowbizCoreUtmSuite {

    private static let dayMs: Int64 = 24 * 60 * minuteMs
    private let journey: (url: String, expected: String)
    private var probe = 0

    init() throws {
        journey = try UtmLinkParserSuite.extractVector("messagebuilder_journey_cart_recovery")
    }

    private func harness(appId: String = "77777", store: FakeKeyValueStore = FakeKeyValueStore(), clock: FakeClock = FakeClock()) -> CoreHarness {
        CoreHarness(config: FlowbizConfig(appId: appId, baseUri: "https://store.com"), store: store, clock: clock)
    }

    // A new coupon per probe: dedup would suppress a repeated payload.
    private func trackProbe(_ h: CoreHarness) throws -> String? {
        probe += 1
        h.core.track(.cartSetCoupon(cartId: "c-1", coupon: "probe-\(probe)"))
        return utm(try h.lastEntry())
    }

    private func utm(_ entry: [String: Any]) -> String? { object(entry, "context")["utm"] as? String }

    private func last(_ h: CoreHarness, _ event: String) throws -> [String: Any] {
        try #require(try h.sentEntries().last { $0["event"] as? String == event }, "\(event)")
    }

    private func expiry(_ h: CoreHarness) -> Int64? { h.store[StorageKeys.utmExpiresAtWallMs] as? Int64 }

    @Test func aLinkPutsContextUtmOnEveryEntryBuiltAfterIt() throws {
        let h = harness()
        h.sender.defaultResult = .retriableError
        h.core.track(.cartSetCoupon(cartId: "c-1", coupon: "queued-before-the-link"))
        h.sender.defaultResult = .success
        _ = Flowbiz.handleLink(journey.url, core: h.core)
        h.core.track(.cartSetCoupon(cartId: "c-1", coupon: "after-the-link"))
        let flushed = try h.sentEntries().suffix(2).map(utm)
        #expect(flushed == [nil, journey.expected])

        h.core.onForeground()
        h.scheduler.tickRepeating()
        #expect(utm(try last(h, "page.ping")) == journey.expected)
        h.core.setPushToken("tok")
        #expect(utm(try last(h, "push.token.sync")) == journey.expected)
    }

    @Test func handleLinkThenTrackFromTheSameThreadOnTheRealScheduler() throws {
        let serialQueue = DispatchQueue(label: "br.com.flowbiz.onsite.tests.utm")
        let store = FakeKeyValueStore()
        // Expired: the startup load discards it, so it outlives the init only if that load is deferred.
        let stale = #"[["utm_source","stale"]]"#
        store[StorageKeys.utmData] = stale
        store[StorageKeys.utmExpiresAtWallMs] = Int64(0)
        let sender = FakeHttpSender()
        let sent = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        sender.onSend = { _ in sent.signal() }
        serialQueue.async { release.wait() }
        let queue = EventQueue(fileURL: temporaryQueueFile())
        let core = FlowbizCore(
            config: FlowbizConfig(appId: "77777", baseUri: "https://store.com"),
            store: store,
            queueFactory: { queue },
            sender: sender,
            scheduler: DispatchTaskScheduler(queue: serialQueue),
            clock: FakeClock(),
            deviceContext: DeviceContext(language: "pt-BR", screen: { "1170x2532" }, timezoneOffsetMinutes: { _ in -180 }),
            reachability: FakeReachability()
        )

        _ = Flowbiz.handleLink(journey.url, core: core)
        core.track(.cartSetCoupon(cartId: "c-1", coupon: "after-the-link"))
        #expect(store[StorageKeys.utmData] as? String == stale, "loaded or captured on the caller's thread")
        release.signal()

        #expect(sent.wait(timeout: .now() + 5) == .success)
        let body = try #require(serialQueue.sync { sender.bodies.first })
        let root = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let entry = try #require((root["data"] as? [[String: Any]])?.first)
        #expect(utm(entry) == journey.expected)
    }

    @Test func everySequenceVectorHoldsThroughTheCoreAndARestart() throws {
        for sequence in try #require(try UtmLinkParserSuite.vectors()["sequences"] as? [[String: Any]]) {
            let name = sequence["name"] as? String ?? "?"
            let h = harness()
            var expected: String?
            for (index, step) in try #require(sequence["steps"] as? [[String: Any]]).enumerated() {
                if let url = step["url"] as? String {
                    _ = Flowbiz.handleLink(url, core: h.core)
                } else {
                    h.core.onBackground()
                    h.core.onForeground()
                }
                expected = step["expected"] as? String
                #expect(UtmLinkParserSuite.bytes(try trackProbe(h)) == UtmLinkParserSuite.bytes(expected), "\(name) step \(index)")
            }
            let restarted = harness(store: h.store, clock: h.clock)
            #expect(UtmLinkParserSuite.bytes(try trackProbe(restarted)) == UtmLinkParserSuite.bytes(expected), "\(name) restarted")
        }
    }

    @Test func theEnvelopeVectorPinsContextUtmEscaping() throws {
        let envelope = try #require(try UtmLinkParserSuite.vectors()["envelope"] as? [String: Any])
        let utm = try #require(envelope["utm"] as? String)
        let contextCanonical = try #require(envelope["context_canonical"] as? String)
        let h = harness()
        _ = Flowbiz.handleLink(try #require(envelope["url"] as? String), core: h.core)

        #expect(UtmLinkParserSuite.bytes(try trackProbe(h)) == UtmLinkParserSuite.bytes(utm))
        #expect(try #require(h.sender.bodies.last).contains(String(contextCanonical.dropFirst().dropLast())))
    }

    @Test func visitsSlideTheExpiryStartupDoesNotAndAnExpiredSetIsDropped() throws {
        let h = harness()
        _ = Flowbiz.handleLink(journey.url, core: h.core)
        #expect(expiry(h) == h.clock.wall + 30 * Self.dayMs)
        h.clock.advance(10 * Self.dayMs)
        h.core.onForeground()
        #expect(expiry(h) == h.clock.wall + 30 * Self.dayMs)
        let lastVisit = h.clock.wall

        h.clock.advance(10 * Self.dayMs)
        let restarted = harness(store: h.store, clock: h.clock)
        #expect(try trackProbe(restarted) == journey.expected)
        #expect(expiry(restarted) == lastVisit + 30 * Self.dayMs)

        h.clock.advance(20 * Self.dayMs)
        #expect(try trackProbe(restarted) == journey.expected)
        restarted.core.onForeground()
        #expect(try trackProbe(restarted) == nil)
        #expect(restarted.store[StorageKeys.utmData] == nil)
        #expect(expiry(restarted) == nil)
    }

    @Test func aLinkCapturedWhileDisabledIsStoredAndSentOnceReEnabled() throws {
        let h = harness()
        h.core.setEnabled(false)
        h.core.setPushToken("tok")
        _ = Flowbiz.handleLink(journey.url, core: h.core)
        h.core.track(.cartSetCoupon(cartId: "c-1", coupon: "while-disabled"))
        #expect(h.sender.bodies.isEmpty)
        #expect(h.store[StorageKeys.utmData] != nil)

        h.core.setEnabled(true)
        #expect(utm(try last(h, "push.token.sync")) == journey.expected)
        #expect(try trackProbe(h) == journey.expected)
    }

    @Test func logoutKeepsTheUtms() throws {
        let h = harness()
        _ = Flowbiz.handleLink(journey.url, core: h.core)
        h.core.track(.accountLogin(user: User(userId: "u-1", email: "a@b.com")))
        h.core.setPushToken("tok")
        h.core.logout()
        #expect(utm(try last(h, "push.token.remove")) == journey.expected)
        #expect(try trackProbe(h) == journey.expected)
        #expect(try trackProbe(harness(store: h.store, clock: h.clock)) == journey.expected)
    }

    @Test func captureDoesNotDependOnTheRecoveryDecode() throws {
        let google = journey.url.replacingOccurrences(of: "utm_source=flowbiz", with: "utm_source=google")
        try #require(google != journey.url)
        let thirdParty = try UtmLinkParserSuite.extractVector("third_party_campaign")
        let cases: [(name: String, appId: String, url: String, expected: String, cartId: String?)] = [
            ("recovery link", "77777", journey.url, journey.expected, "cart-abc-001"),
            ("another tenant's cart", "88888", journey.url, journey.expected, nil),
            ("foreign utm_source", "77777", google, journey.expected.replacingOccurrences(of: "\"flowbiz\"", with: "\"google\""), nil),
            ("no _mb_cr_", "77777", thirdParty.url, thirdParty.expected, nil),
        ]
        for (name, appId, url, expected, cartId) in cases {
            let h = harness(appId: appId)
            #expect(Flowbiz.handleLink(url, core: h.core)?.cartId == cartId, "\(name)")
            #expect(try trackProbe(h) == expected, "\(name)")
        }
    }

    @Test func handlePushOpenedCapturesTheRawDeepLinkAndHandlePushNothing() throws {
        let link = journey.url.replacingOccurrences(of: "carrinho-abandonado", with: "carrinho%20abandonado")
        try #require(link != journey.url)
        let marker = try JSONSerialization.data(withJSONObject: ["v": 1, "type": "cart_recovery", "deep_link": link])
        let h = harness()
        try Flowbiz.$taskCore.withValue(h.core) {
            let push = try #require(Flowbiz.handlePush(["flowbiz": String(decoding: marker, as: UTF8.self)]))
            #expect(push.deepLink?.absoluteString.contains("carrinho%20abandonado") == true)
            _ = push.recoveryPayload
            #expect(try trackProbe(h) == nil)
            #expect(Flowbiz.handlePushOpened(push)?.cartId == "cart-abc-001")
        }
        #expect(try trackProbe(h) == journey.expected.replacingOccurrences(of: "carrinho-abandonado", with: "carrinho abandonado"))
    }

    @Test func theLandingPageViewCarriesANewCaptureWhileAnIdenticalPayloadStaysDeduped() throws {
        let h = harness()
        h.core.track(.pageView(path: "/carrinho"))
        h.core.track(.cartSetCoupon(cartId: "c-1", coupon: "same"))
        _ = Flowbiz.handleLink(journey.url, core: h.core)
        h.clock.advance(minuteMs)
        h.core.track(.pageView(path: "/carrinho"))
        h.core.track(.cartSetCoupon(cartId: "c-1", coupon: "same"))
        #expect(try h.sentEntries().count == 3)
        #expect(utm(try last(h, "page.view")) == journey.expected)
    }

    @Test func thePublicHandleLinkReachesTheInstalledCore() throws {
        let link = journey.url.replacingOccurrences(of: "|", with: "%7C")
        for (appId, cartId) in [("77777", "cart-abc-001"), ("88888", nil)] as [(String, String?)] {
            let h = harness(appId: appId)
            let payload = Flowbiz.$taskCore.withValue(h.core) { Flowbiz.handleLink(URL(string: link)) }
            #expect(payload?.cartId == cartId, "\(appId)")
            #expect(try trackProbe(h) == journey.expected, "\(appId)")
        }
    }
}
#endif
