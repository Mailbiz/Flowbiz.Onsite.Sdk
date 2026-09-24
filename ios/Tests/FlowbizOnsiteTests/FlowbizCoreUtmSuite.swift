// SPEC §11.1 UTM attribution through `FlowbizCore`: capture from links,
// `context.utm` stamping on every envelope kind, the evaluation points
// (capture, foreground, re-enable) and the read-only startup load, the
// sliding 30-day expiry, the disabled-state purge, what never touches UTM
// state (logout, disable), and the facade's `handleLink` /
// `handlePushOpened` capture rules through their String seams.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct FlowbizCoreUtmSuite {

    private static let dayMs: Int64 = 24 * 60 * minuteMs

    private let cart = Event.cartSync(
        cart: Cart(cartId: "cart-abc-001", subtotal: 100, total: 100, freight: 0, tax: 0, discounts: 0)
    )

    /// The MessageBuilder journey link and the exact `context.utm` string
    /// the web tag sends for it (`shared/utm-links/vectors.json`).
    private static func journeyVector() throws -> (url: String, expected: String) {
        try extractVector("messagebuilder_journey_cart_recovery")
    }

    private static func extractVector(_ name: String) throws -> (url: String, expected: String) {
        let vectors = try #require(try UtmLinkParserSuite.vectors()["extract"] as? [[String: Any]])
        let vector = try #require(vectors.first { $0["name"] as? String == name }, "\(name)")
        return (try #require(vector["url"] as? String), try #require(vector["expected"] as? String))
    }

    private func utm(_ entry: [String: Any]) -> String? {
        object(entry, "context")["utm"] as? String
    }

    private func bytes(_ value: String?) -> [UInt8]? {
        value.map { Array($0.utf8) }
    }

    private func expiry(_ store: FakeKeyValueStore) -> Int64? {
        store[StorageKeys.utmExpiresAtWallMs] as? Int64
    }

    // MARK: Capture → wire

    @Test func captureThenTrackCarriesTheWebContextUtmString() throws {
        let (url, expected) = try Self.journeyVector()
        let h = CoreHarness()
        h.core.captureUtm(fromLink: url)
        h.core.track(cart)

        #expect(bytes(utm(try h.lastEntry())) == bytes(expected))
        #expect(expiry(h.store) == h.clock.wall + UtmStore.ttlMillis)
        // Canonical outer bytes: a JSON string inside `context`, `url` < `utm` < `vendor`.
        let body = try #require(h.sender.bodies.last)
        #expect(body.contains(#""utm":"{\"utm_source\":\"flowbiz\",\"utm_medium\":\"email\","#))
    }

    @Test func eventsBeforeAnyCaptureCarryNoUtmAndNothingIsStored() throws {
        let h = CoreHarness()
        h.core.track(.pageView(path: "home"))
        #expect(utm(try h.lastEntry()) == nil)
        #expect(h.store[StorageKeys.utmData] == nil)
        #expect(h.store[StorageKeys.utmExpiresAtWallMs] == nil)
    }

    @Test func linkWithoutUtmsLeavesTheContextUnset() throws {
        let h = CoreHarness()
        h.core.captureUtm(fromLink: "https://store.com/produto/1?foo=bar&utm_term=x")
        h.core.track(.pageView(path: "home"))
        #expect(utm(try h.lastEntry()) == nil)
        #expect(h.store[StorageKeys.utmData] == nil)
    }

    /// SPEC §11.1: capture does not depend on the recovery decode — a link
    /// with no `_mb_cr_`, a foreign `utm_source` or another tenant's cart
    /// still has its UTMs captured.
    @Test func nonRecoveryLinksStillCapture() throws {
        let foreignTenantHash = Data(#"{"t":"99999","u":"u","c":"c","its":[["1","P","S"]]}"#.utf8).base64EncodedString()
        let links = [
            ("https://store.com/produto/1?utm_source=google&utm_medium=cpc", #"{"utm_source":"google","utm_medium":"cpc"}"#),
            ("https://store.com/carrinho?utm_source=flowbiz&_mb_cr_=\(foreignTenantHash)", #"{"utm_source":"flowbiz"}"#),
        ]
        for (link, expected) in links {
            #expect(RecoveryLinkParser.parse(link, expectedAppId: "77777") == nil)
            let h = CoreHarness()
            h.core.captureUtm(fromLink: link)
            h.core.track(.pageView(path: "home"))
            #expect(utm(try h.lastEntry()) == expected, "\(link)")
        }
    }

    @Test func pingCarriesTheCapturedUtm() throws {
        let h = CoreHarness()
        h.core.onForeground()
        h.core.captureUtm(fromLink: "https://store.com/?utm_source=flowbiz&utm_journey=16")
        h.scheduler.tickRepeating()
        let ping = try #require(try h.sentEntries().last { $0["event"] as? String == "page.ping" })
        #expect(utm(ping) == #"{"utm_source":"flowbiz","utm_journey":"16"}"#)
    }

    @Test func rawPushTokenSyncCarriesTheCapturedUtm() throws {
        let h = CoreHarness()
        h.core.captureUtm(fromLink: "https://store.com/?utm_source=flowbiz")
        h.core.setPushToken("tok")
        let sync = try #require(try h.sentEntries().last { $0["event"] as? String == "push.token.sync" })
        #expect(utm(sync) == #"{"utm_source":"flowbiz"}"#)
    }

    /// The context is frozen when the envelope is built (SPEC §11.1 step 5):
    /// a queued entry is never rewritten by a later capture — flush only
    /// restamps `sent_at`.
    @Test func entryQueuedBeforeACaptureKeepsItsContext() throws {
        let h = CoreHarness()
        h.sender.defaultResult = .retriableError
        h.core.track(.pageView(path: "home")) // queued, delivery failed
        let queuedHash = try h.lastEntry()["hash"] as? String

        h.core.captureUtm(fromLink: "https://store.com/?utm_source=flowbiz")
        h.sender.defaultResult = .success
        h.core.flush()
        let delivered = try h.lastEntry()
        #expect(delivered["hash"] as? String == queuedHash)
        #expect(utm(delivered) == nil)
        #expect(h.queue.size == 0)

        h.core.track(.pageView(path: "next"))
        #expect(utm(try h.lastEntry()) == #"{"utm_source":"flowbiz"}"#)
    }

    @Test func laterLinksMergePerKey() throws {
        let h = CoreHarness()
        h.core.captureUtm(fromLink: "https://store.com/?utm_campaign=c1&utm_source=mailbiz")
        h.core.captureUtm(fromLink: "https://store.com/?utm_medium=cpc&utm_source=google&utm_campaign=")
        h.core.track(.pageView(path: "home"))
        #expect(utm(try h.lastEntry()) == #"{"utm_source":"google","utm_campaign":"c1","utm_medium":"cpc"}"#)
    }

    /// The shared web sequences through the real evaluation points: a
    /// `url` is a `captureUtm`, a null `url` a foreground edge (an
    /// evaluation without a link). The event tracked after each step
    /// carries the web's string.
    @Test func sharedSequencesHoldThroughTheCoreEvaluationPoints() throws {
        let sequences = try #require(try UtmLinkParserSuite.vectors()["sequences"] as? [[String: Any]])
        for sequence in sequences {
            let name = sequence["name"] as? String ?? "?"
            let steps = try #require(sequence["steps"] as? [[String: Any]], "\(name): steps")
            let h = CoreHarness()
            h.core.onForeground()
            for (index, step) in steps.enumerated() {
                if let url = step["url"] as? String {
                    h.core.captureUtm(fromLink: url)
                } else {
                    h.core.onBackground()
                    h.core.onForeground()
                }
                h.core.track(.pageView(path: "\(name)/\(index)")) // distinct: never deduped
                #expect(bytes(utm(try h.lastEntry())) == bytes(step["expected"] as? String), "\(name) step \(index)")
            }
        }
    }

    /// SPEC §11.1 at the facade, through its String seam: `handleLink`
    /// hands every link to the capture whatever the recovery decode
    /// returns (a payload for this tenant, no `_mb_cr_`, a foreign
    /// `utm_source`, another tenant's link), and the next event carries
    /// that link's UTMs. Uninitialized (nil core), it still decodes and
    /// captures nothing. (`DebugLogRedactionSuite` pins that the core-less
    /// path logs no handler or initialize warning; that it captures
    /// nothing is structural — `core?.` — with no store to observe.)
    @Test func handleLinkCapturesWhateverTheRecoveryDecodeReturns() throws {
        let (url, expected) = try Self.journeyVector()
        let thirdParty = try Self.extractVector("third_party_campaign")
        func check(_ label: String, appId: String, link: String, decodes: Bool, expected: String) throws {
            let h = CoreHarness(config: FlowbizConfig(appId: appId, baseUri: "https://store.com"))
            #expect((Flowbiz.handleLink(link, core: h.core) != nil) == decodes, "\(label)")
            h.core.track(cart)
            #expect(bytes(utm(try h.lastEntry())) == bytes(expected), "\(label)")
        }
        try check("recovery link for this tenant", appId: "77777", link: url, decodes: true, expected: expected)
        try check("no _mb_cr_", appId: "77777", link: thirdParty.url, decodes: false, expected: thirdParty.expected)
        try check(
            "foreign utm_source", appId: "77777",
            link: url.replacingOccurrences(of: "utm_source=flowbiz", with: "utm_source=google"),
            decodes: false,
            expected: #"{"utm_source":"google","utm_medium":"email","utm_campaign":"jornadas|cart|carrinho-abandonado","#
                + #""utm_journey":"16","utm_journey_channel":"email","utm_journey_type":"1"}"#
        )
        try check("tenant mismatch", appId: "88888", link: url, decodes: false, expected: expected)

        #expect(Flowbiz.handleLink(url, core: nil) != nil) // uninitialized: decodes, no tenant check
        let h = CoreHarness()
        #expect(Flowbiz.handleLink(nil, core: h.core) == nil)
        #expect(h.store[StorageKeys.utmData] == nil)
    }

    // MARK: Facade: handlePushOpened (through its String seam)

    /// A push as `handlePush` returns it. The marker is JSON-encoded, as
    /// the SPEC §10.2 contract prescribes; `deep_link` is omitted when nil.
    private static func push(deepLink: String?) throws -> FlowbizPush {
        var marker: [String: Any] = ["v": 1, "type": "cart_recovery"]
        if let deepLink { marker["deep_link"] = deepLink }
        let json = try #require(String(data: try JSONSerialization.data(withJSONObject: marker), encoding: .utf8))
        let push = try #require(Flowbiz.handlePush(["flowbiz": json]))
        #expect(push.deepLinkString.map { Array($0.utf16) } == deepLink.map { Array($0.utf16) })
        return push
    }

    /// The `_mb_cr_` hash of the `basic` recovery vector
    /// (`shared/recovery-links/vectors.json`): cart-abc-001 for appId 77777.
    private static let basicRecoveryHash =
        "eyJ0IjoiNzc3NzciLCJ1IjoidXNlci0xMjMiLCJjIjoiY2FydC1hYmMtMDAxIiwiaXRzIjpbWyIyIiwiUDEwMCIsIlNLVS0xMDAtUCJdLFsiMSIsIlAyMDAiLCJTS1UtMjAwLU0iXV19"

    /// SPEC §10.2/§11.1: every shared UTM vector (SPEC §14) used as a
    /// tapped push's `deep_link`. `handlePushOpened` captures exactly the
    /// web's `context.utm` on the next event, and nothing when the web
    /// sends none.
    @Test func handlePushOpenedCapturesEveryUtmVectorFromTheRawDeepLink() throws {
        let vectors = try #require(try UtmLinkParserSuite.vectors()["extract"] as? [[String: Any]])
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let raw = try #require(vector["url"] as? String, "\(name): url")
            let expected = vector["expected"] as? String // null ⇔ no `utm` key
            let push = try Self.push(deepLink: raw)
            let h = CoreHarness()
            _ = Flowbiz.handlePushOpened(push, core: h.core)
            h.core.track(.pageView(path: name))
            #expect(bytes(utm(try h.lastEntry())) == bytes(expected), "\(name)")
        }
    }

    /// SPEC §10.2: links whose `URL` round trip loses or changes what is
    /// captured. On iOS 13–18 Foundation turns the `#` of a rootless custom
    /// scheme into `%23`, so the fragment lands in the last UTM value. On
    /// iOS 13–16 it rejects a raw `|`, a non-ASCII host, a bare `%`, `[`/`]`
    /// in the query or a second `#` (no URL, nothing captured). On iOS 17+
    /// it accepts them only by re-encoding the link's own escapes (`%20` →
    /// `%2520`). Read from the raw `deep_link`, each link captures exactly
    /// what web and Android send. The `web` strings come from running the
    /// web tag's `url.ts` on the raw links.
    @Test func handlePushOpenedCapturesLinksAURLRoundTripWouldAlter() throws {
        let journey = try Self.journeyVector()
        let cases: [(raw: String, web: String)] = [
            // A rootless custom scheme with a fragment.
            ("myapp:cart?utm_source=flowbiz&utm_medium=push&utm_journey_type=1#promo",
             #"{"utm_source":"flowbiz","utm_medium":"push","utm_journey_type":"1"}"#),
            // MessageBuilder writes the campaign's `|` raw.
            (journey.url, journey.expected),
            // A raw `|` and a `%20` escape in one value.
            ("https://store.com/?utm_campaign=a|b%20c&utm_source=s",
             #"{"utm_source":"s","utm_campaign":"a|b c"}"#),
            // An IDN host.
            ("https://café.com/promo?utm_source=flowbiz&utm_campaign=a|b",
             #"{"utm_source":"flowbiz","utm_campaign":"a|b"}"#),
            // A bare `%`, with a valid escape elsewhere in the link.
            ("https://store.com/?utm_campaign=Black%20Friday&utm_medium=100%",
             #"{"utm_medium":"100%","utm_campaign":"Black Friday"}"#),
            // `[` / `]` outside the host, and an IPv6 literal host.
            ("https://store.com/?utm_campaign=promo[1]&utm_medium=e%20mail",
             #"{"utm_medium":"e mail","utm_campaign":"promo[1]"}"#),
            ("https://[::1]:8080/p?utm_source=a|b&utm_medium=e%20mail",
             #"{"utm_source":"a|b","utm_medium":"e mail"}"#),
            // A second `#`, and a hash route with a `#` after its query
            // (MessageBuilder's fragment shape): web cuts the query there.
            ("https://store.com/?utm_campaign=a|b&utm_medium=e%20mail#top#x",
             #"{"utm_medium":"e mail","utm_campaign":"a|b"}"#),
            ("https://store.com/#/cart?utm_source=a|b&utm_medium=e%20mail#/cart",
             #"{"utm_source":"a|b","utm_medium":"e mail"}"#),
            // Web sends a value it cannot decode raw, valid escapes included.
            ("https://store.com/?utm_campaign=Black%20Friday 50%&utm_medium=e%20mail",
             #"{"utm_medium":"e mail","utm_campaign":"Black%20Friday 50%"}"#),
            ("https://store.com/?utm_campaign=50%%20off&utm_source=s",
             #"{"utm_source":"s","utm_campaign":"50%%20off"}"#),
            ("https://store.com/?utm_campaign=a|b%C3&utm_source=%E2%82%AC",
             #"{"utm_source":"€","utm_campaign":"a|b%C3"}"#),
        ]
        for (raw, web) in cases {
            #expect(UtmLinkParser.render(UtmLinkParser.extract(raw)) == web, "port vs web: \(raw)")
            let push = try Self.push(deepLink: raw)
            let h = CoreHarness()
            _ = Flowbiz.handlePushOpened(push, core: h.core)
            h.core.track(cart)
            #expect(bytes(utm(try h.lastEntry())) == bytes(web), "\(raw)")
        }
    }

    /// The tap's result is `handleLink` over the raw `deep_link`: the
    /// recovery payload checked against this tenant. On a mismatch it is
    /// nil and the UTMs are still captured. `recoveryPayload` stays pure
    /// and skips the tenant check. Links a `URL` round trip would alter
    /// decode the same way: a rootless link keeps its recovery, and a hash
    /// route with a later `#` stays nil, as on Android.
    @Test func handlePushOpenedReturnsTheTenantCheckedHandleLinkResult() throws {
        let (url, expected) = try Self.journeyVector()
        let hash = Self.basicRecoveryHash
        let cases: [(label: String, appId: String, link: String, cartId: String?, utm: String)] = [
            ("this tenant", "77777", url, "cart-abc-001", expected),
            ("tenant mismatch", "88888", url, nil, expected),
            ("rootless custom scheme", "77777", "myapp:cart?utm_source=flowbiz&_mb_cr_=\(hash)#promo",
             "cart-abc-001", #"{"utm_source":"flowbiz"}"#),
            ("hash route with a later #", "77777", "https://store.com/#/cart?_mb_cr_=\(hash)&utm_source=flowbiz#/cart",
             nil, #"{"utm_source":"flowbiz"}"#),
        ]
        for (label, appId, link, cartId, expectedUtm) in cases {
            let config = FlowbizConfig(appId: appId, baseUri: "https://store.com")
            let push = try Self.push(deepLink: link)
            let h = CoreHarness(config: config)
            let opened = Flowbiz.handlePushOpened(push, core: h.core)
            #expect(opened?.cartId == cartId, "\(label)")
            #expect(opened == Flowbiz.handleLink(link, core: CoreHarness(config: config).core), "\(label)")
            #expect(push.recoveryPayload == RecoveryLinkParser.parse(link), "\(label): recoveryPayload")
            h.core.track(cart)
            #expect(bytes(utm(try h.lastEntry())) == bytes(expectedUtm), "\(label)")
        }
        // Pure `recoveryPayload`: no tenant check, so the mismatch decodes.
        let push = try Self.push(deepLink: url)
        #expect(push.recoveryPayload?.cartId == "cart-abc-001")
    }

    /// No push, or a push without `deep_link`, returns nil and is no
    /// evaluation. A stored set keeps its expiry, unlike a capture of a
    /// link with no UTMs, which slides it.
    @Test func handlePushOpenedWithoutADeepLinkIsNilAndCapturesNothing() throws {
        let h = CoreHarness()
        h.core.captureUtm(fromLink: "https://store.com/?utm_source=flowbiz")
        let capturedExpiry = expiry(h.store)
        h.clock.advance(Self.dayMs)

        let withoutDeepLink = try Self.push(deepLink: nil)
        #expect(Flowbiz.handlePushOpened(nil, core: h.core) == nil)
        #expect(Flowbiz.handlePushOpened(withoutDeepLink, core: h.core) == nil)
        #expect(expiry(h.store) == capturedExpiry)
        h.core.track(.pageView(path: "home"))
        #expect(utm(try h.lastEntry()) == #"{"utm_source":"flowbiz"}"#)
        // The public entry, whatever the singleton's state: no link, nil.
        #expect(Flowbiz.handlePushOpened(nil) == nil)
        #expect(Flowbiz.handlePushOpened(withoutDeepLink) == nil)
    }

    /// Before initialize (nil core) the tap still decodes, without the
    /// tenant check, and captures nothing: no store is open.
    /// (`DebugLogRedactionSuite` pins that it logs no warning.)
    @Test func handlePushOpenedBeforeInitializeDecodesOnly() throws {
        let (url, _) = try Self.journeyVector()
        let otherTenant = url.replacingOccurrences(of: Self.basicRecoveryHash, with: Data(
            #"{"t":"99999","u":"u","c":"c-99","its":[["1","P","S"]]}"#.utf8
        ).base64EncodedString())
        let push = try Self.push(deepLink: url)
        let otherTenantPush = try Self.push(deepLink: otherTenant)
        #expect(Flowbiz.handlePushOpened(push, core: nil)?.cartId == "cart-abc-001")
        #expect(Flowbiz.handlePushOpened(otherTenantPush, core: nil)?.cartId == "c-99")
    }

    // MARK: Persistence + evaluation points

    /// SPEC §11.1 item 4: startup only loads. A new process (same store)
    /// stamps the stored UTMs on its first event with no link, but leaves
    /// the expiry alone: a process start is not a visit (a push or a
    /// background job can wake the app without the user). The first
    /// foreground transition is the visit that slides it to now + 30 days.
    @Test func restartCarriesTheStoredUtmWithoutALinkButOnlyAForegroundSlidesTheExpiry() throws {
        let (url, expected) = try Self.journeyVector()
        let store = FakeKeyValueStore()
        let clock = FakeClock()
        let first = CoreHarness(store: store, clock: clock)
        first.core.captureUtm(fromLink: url)
        let capturedExpiry = expiry(store)

        clock.advance(10 * Self.dayMs)
        let second = CoreHarness(store: store, clock: clock)
        second.core.track(cart)
        #expect(bytes(utm(try second.lastEntry())) == bytes(expected))
        #expect(expiry(store) == capturedExpiry)

        second.core.onForeground()
        #expect(expiry(store) == clock.wall + UtmStore.ttlMillis)
    }

    /// Background-only launches never keep the set alive: captured on day
    /// 0, then a new process every 20 days that is never foregrounded (a
    /// push or background job each time). Day 20 still carries the set; by
    /// day 40 it has expired, both keys are gone and events carry no
    /// `context.utm`.
    @Test func backgroundOnlyRestartsLetTheUtmExpire() throws {
        let store = FakeKeyValueStore()
        let clock = FakeClock()
        CoreHarness(store: store, clock: clock).core
            .captureUtm(fromLink: "https://store.com/?utm_source=flowbiz&utm_journey=16")
        let capturedExpiry = expiry(store)

        clock.advance(20 * Self.dayMs)
        let dayTwenty = CoreHarness(store: store, clock: clock)
        dayTwenty.core.track(.pageView(path: "day-20"))
        #expect(utm(try dayTwenty.lastEntry()) == #"{"utm_source":"flowbiz","utm_journey":"16"}"#)
        #expect(expiry(store) == capturedExpiry)

        clock.advance(20 * Self.dayMs)
        let dayForty = CoreHarness(store: store, clock: clock)
        #expect(store[StorageKeys.utmData] == nil)
        #expect(store[StorageKeys.utmExpiresAtWallMs] == nil)
        dayForty.core.track(.pageView(path: "day-40"))
        #expect(utm(try dayForty.lastEntry()) == nil)
    }

    @Test func foregroundAtDayTwentyNineSlidesTheExpiryToDayFiftyNine() throws {
        let store = FakeKeyValueStore()
        let clock = FakeClock()
        let start = clock.wall
        let h = CoreHarness(store: store, clock: clock)
        h.core.captureUtm(fromLink: "https://store.com/?utm_source=flowbiz")
        #expect(expiry(store) == start + 30 * Self.dayMs)

        clock.advance(29 * Self.dayMs)
        h.core.onForeground()
        #expect(expiry(store) == start + 59 * Self.dayMs)

        // Day 58 — long past the original expiry — a restart still finds
        // it, and leaves the slid expiry as is (startup only loads).
        clock.advance(29 * Self.dayMs)
        let restarted = CoreHarness(store: store, clock: clock)
        restarted.core.track(.pageView(path: "home"))
        #expect(utm(try restarted.lastEntry()) == #"{"utm_source":"flowbiz"}"#)
        #expect(expiry(store) == start + 59 * Self.dayMs)
    }

    @Test func oneMillisecondBeforeExpiryTheNextEvaluationKeepsIt() throws {
        let h = CoreHarness()
        h.core.captureUtm(fromLink: "https://store.com/?utm_source=flowbiz")
        h.clock.advance(UtmStore.ttlMillis - 1)
        h.core.onForeground()
        #expect(expiry(h.store) == h.clock.wall + UtmStore.ttlMillis)
        h.core.track(.pageView(path: "home"))
        #expect(utm(try h.lastEntry()) == #"{"utm_source":"flowbiz"}"#)
    }

    /// A capture is an evaluation even when the link has no UTMs (web: a
    /// page load without them): the stored set is kept and its expiry slid.
    @Test func aLaterLinkWithoutUtmsKeepsTheSetAndSlidesTheExpiry() throws {
        let (url, expected) = try Self.journeyVector()
        let h = CoreHarness()
        h.core.captureUtm(fromLink: url)
        h.clock.advance(5 * Self.dayMs)
        h.core.captureUtm(fromLink: "https://store.com/produto/1")
        #expect(expiry(h.store) == h.clock.wall + UtmStore.ttlMillis)
        h.core.track(cart)
        #expect(bytes(utm(try h.lastEntry())) == bytes(expected))
    }

    /// Web page-lifetime semantics: the in-memory value keeps riding
    /// *between* evaluation points even past the stored expiry (a web page
    /// never re-reads storage mid-page), on events and pings alike; the
    /// next evaluation point drops it and removes both keys.
    @Test func expiredUtmRidesUntilTheNextEvaluationPointThenIsDropped() throws {
        let h = CoreHarness()
        h.core.onForeground()
        h.core.captureUtm(fromLink: "https://store.com/?utm_source=flowbiz")
        h.clock.advance(UtmStore.ttlMillis) // exactly at expiry: expired

        h.core.track(.pageView(path: "still-on-the-page"))
        #expect(utm(try h.lastEntry()) == #"{"utm_source":"flowbiz"}"#)
        h.scheduler.tickRepeating()
        let ping = try #require(try h.sentEntries().last { $0["event"] as? String == "page.ping" })
        #expect(utm(ping) == #"{"utm_source":"flowbiz"}"#)
        #expect(h.store[StorageKeys.utmData] != nil)

        h.core.onBackground()
        h.core.onForeground() // evaluation point
        #expect(h.store[StorageKeys.utmData] == nil)
        #expect(h.store[StorageKeys.utmExpiresAtWallMs] == nil)
        h.core.track(.pageView(path: "after"))
        #expect(utm(try h.lastEntry()) == nil)
    }

    @Test func expiredUtmIsDroppedAtStartup() throws {
        let store = FakeKeyValueStore()
        let clock = FakeClock()
        CoreHarness(store: store, clock: clock).core.captureUtm(fromLink: "https://store.com/?utm_source=flowbiz")
        clock.advance(UtmStore.ttlMillis)
        let restarted = CoreHarness(store: store, clock: clock)
        #expect(store[StorageKeys.utmData] == nil)
        restarted.core.track(.pageView(path: "home"))
        #expect(utm(try restarted.lastEntry()) == nil)
    }

    @Test func corruptStoredUtmIsRemovedAtStartup() throws {
        let store = FakeKeyValueStore()
        store[StorageKeys.utmData] = "{not json"
        store[StorageKeys.utmExpiresAtWallMs] = FakeClock().wall + Self.dayMs
        let h = CoreHarness(store: store)
        #expect(store[StorageKeys.utmData] == nil)
        #expect(store[StorageKeys.utmExpiresAtWallMs] == nil)
        h.core.track(.pageView(path: "home"))
        #expect(utm(try h.lastEntry()) == nil)
    }

    // MARK: What never touches UTM state

    /// UTMs describe the traffic source, not the user — web never clears
    /// them, so neither does logout (nor an account change).
    @Test func logoutKeepsTheUtm() throws {
        let h = CoreHarness()
        h.core.captureUtm(fromLink: "https://store.com/?utm_source=flowbiz")
        h.core.track(.accountLogin(user: User(userId: "u-1", email: "a@b.com")))
        h.core.setPushToken("tok")
        h.core.logout()
        let removal = try #require(try h.sentEntries().last { $0["event"] as? String == "push.token.remove" })
        #expect(utm(removal) == #"{"utm_source":"flowbiz"}"#)
        h.core.track(.pageView(path: "home"))
        #expect(utm(try h.lastEntry()) == #"{"utm_source":"flowbiz"}"#)
        #expect(h.store[StorageKeys.utmData] != nil)
    }

    /// SPEC §12: while disabled no UTMs are captured — nothing is written
    /// and nothing surfaces after re-enabling.
    @Test func captureWhileDisabledWritesNothingAndNeverSurfaces() throws {
        let h = CoreHarness()
        h.core.setEnabled(false)
        h.core.captureUtm(fromLink: "https://store.com/?utm_source=flowbiz")
        #expect(h.store[StorageKeys.utmData] == nil)
        #expect(h.store[StorageKeys.utmExpiresAtWallMs] == nil)

        h.core.setEnabled(true)
        h.core.track(.pageView(path: "home"))
        #expect(utm(try h.lastEntry()) == nil)
        #expect(h.store[StorageKeys.utmData] == nil)
    }

    @Test func disablingKeepsTheStoredUtm() {
        let h = CoreHarness()
        h.core.captureUtm(fromLink: "https://store.com/?utm_source=flowbiz")
        let stored = h.store[StorageKeys.utmData] as? String
        let storedExpiry = expiry(h.store)
        h.core.setEnabled(false)
        #expect(h.store[StorageKeys.utmData] as? String == stored)
        #expect(expiry(h.store) == storedExpiry)
    }

    /// SPEC §11.1 item 4 / §12: while disabled, startup, foreground, links
    /// and push opens neither read nor refresh a live set. The store stays
    /// exactly as it was, even when `utm_data` is corrupt (a read would
    /// remove it), and `utm_data` is never read. The set does not surface
    /// either: nothing is sent while disabled.
    @Test func aLiveSetIsUntouchedByStartupForegroundAndLinksWhileDisabled() throws {
        let push = try Self.push(deepLink: "https://store.com/?utm_source=push")
        for data in [#"[["utm_source","flowbiz"]]"#, "{not json"] {
            let store = FakeKeyValueStore()
            let clock = FakeClock()
            let storedExpiry = clock.wall + Self.dayMs
            store[StorageKeys.enabled] = false
            store[StorageKeys.utmData] = data
            store[StorageKeys.utmExpiresAtWallMs] = storedExpiry

            let h = CoreHarness(store: store, clock: clock) // startup
            h.core.onForeground()
            h.core.captureUtm(fromLink: "https://store.com/?utm_source=google")
            clock.advance(Self.dayMs - 1) // still live
            h.core.onBackground()
            h.core.onForeground()
            _ = Flowbiz.handleLink("https://store.com/produto/1", core: h.core)
            _ = Flowbiz.handlePushOpened(push, core: h.core)
            _ = CoreHarness(store: store, clock: clock) // another startup
            h.core.track(.pageView(path: "home"))

            #expect(store[StorageKeys.utmData] as? String == data, "\(data)")
            #expect(expiry(store) == storedExpiry, "\(data)")
            #expect(!store.reads.contains(StorageKeys.utmData), "\(data): utm_data read while disabled")
            #expect(h.sender.bodies.isEmpty, "\(data): sent while disabled")
            #expect(h.scheduler.activeRepeating() == nil, "\(data): heartbeat while disabled")
        }
    }

    /// …but an expired set is removed at the next startup, foreground, link
    /// or push open while disabled (SPEC §11.1 item 4), on its expiry
    /// alone: the `utm_data` here is corrupt (a read would discard it as
    /// such at startup, while still live) and it is never read.
    @Test func anExpiredSetIsRemovedAtTheNextEvaluationPointWhileDisabled() throws {
        func disabledStore(expiringAt expiresAt: Int64) -> FakeKeyValueStore {
            let store = FakeKeyValueStore()
            store[StorageKeys.enabled] = false
            store[StorageKeys.utmData] = "{not json"
            store[StorageKeys.utmExpiresAtWallMs] = expiresAt
            return store
        }

        // Startup: a new process on an already expired set.
        let clock = FakeClock()
        let atStartup = disabledStore(expiringAt: clock.wall) // exactly at expiry: expired
        _ = CoreHarness(store: atStartup, clock: clock)
        #expect(atStartup[StorageKeys.utmData] == nil, "startup")
        #expect(atStartup[StorageKeys.utmExpiresAtWallMs] == nil, "startup")
        #expect(!atStartup.reads.contains(StorageKeys.utmData), "startup: utm_data read")

        // Foreground, link and push open on a process started while the
        // set was live.
        let link = "https://store.com/?utm_source=google"
        let push = try Self.push(deepLink: link)
        let triggers: [(name: String, run: (FlowbizCore) -> Void)] = [
            ("foreground", { $0.onForeground() }),
            ("link", { _ = Flowbiz.handleLink(link, core: $0) }),
            ("push open", { _ = Flowbiz.handlePushOpened(push, core: $0) }),
        ]
        for trigger in triggers {
            let clock = FakeClock()
            let store = disabledStore(expiringAt: clock.wall + Self.dayMs)
            let h = CoreHarness(store: store, clock: clock)
            #expect(store[StorageKeys.utmData] != nil, "\(trigger.name): removed while live")
            clock.advance(Self.dayMs) // exactly at expiry
            trigger.run(h.core)
            #expect(store[StorageKeys.utmData] == nil, "\(trigger.name)")
            #expect(store[StorageKeys.utmExpiresAtWallMs] == nil, "\(trigger.name)")
            #expect(!store.reads.contains(StorageKeys.utmData), "\(trigger.name): utm_data read")
        }
    }

    /// Nothing from a disabled period surfaces: the in-memory context of a
    /// set captured before the disable is recomputed at the re-enable. Here
    /// the set expired and was removed while disabled, so the stale value
    /// is not sent after a background re-enable either (the load finds
    /// nothing and clears it).
    @Test func aContextFromBeforeTheDisableIsNotSurfacedOnceItsSetExpiredWhileDisabled() throws {
        let h = CoreHarness()
        h.core.captureUtm(fromLink: "https://store.com/?utm_source=flowbiz")
        h.core.setEnabled(false)
        h.core.captureUtm(fromLink: "https://store.com/?utm_source=while-disabled")
        h.clock.advance(UtmStore.ttlMillis)
        h.core.onForeground() // disabled: removes the expired set only
        #expect(h.store[StorageKeys.utmData] == nil)
        #expect(h.store[StorageKeys.utmExpiresAtWallMs] == nil)
        h.core.onBackground()

        h.core.setEnabled(true) // from the background: a load, which finds nothing
        h.core.track(.pageView(path: "home"))
        #expect(utm(try h.lastEntry()) == nil)
    }

    /// SPEC §11.1 item 4: `setEnabled(true)` while foregrounded is a visit.
    /// It slides the expiry, and it runs before the stored token's
    /// `push.token.sync` re-emit, so that event carries the set.
    @Test func reEnableWhileForegroundedSlidesTheExpiryBeforeTheTokenReEmit() throws {
        let store = FakeKeyValueStore()
        let clock = FakeClock()
        let storedExpiry = clock.wall + Self.dayMs
        store[StorageKeys.enabled] = false
        store[StorageKeys.utmData] = #"[["utm_source","flowbiz"],["utm_journey","16"]]"#
        store[StorageKeys.utmExpiresAtWallMs] = storedExpiry
        let h = CoreHarness(store: store, clock: clock)
        h.core.setPushToken("tok") // persisted, event dropped while disabled
        h.core.onForeground() // disabled: no slide
        #expect(expiry(store) == storedExpiry)

        clock.advance(minuteMs)
        h.core.setEnabled(true)
        let sync = try #require(try h.sentEntries().last { $0["event"] as? String == "push.token.sync" })
        #expect(utm(sync) == #"{"utm_source":"flowbiz","utm_journey":"16"}"#)
        #expect(expiry(store) == clock.wall + UtmStore.ttlMillis)
        h.core.track(.pageView(path: "home"))
        #expect(utm(try h.lastEntry()) == #"{"utm_source":"flowbiz","utm_journey":"16"}"#)
    }

    /// A background re-enable (no foreground since the process started)
    /// only loads the set. The re-emitted `push.token.sync` still carries
    /// it, and the expiry is unchanged.
    @Test func reEnableWhileBackgroundedOnlyLoadsTheSetBeforeTheTokenReEmit() throws {
        let store = FakeKeyValueStore()
        let clock = FakeClock()
        let storedExpiry = clock.wall + Self.dayMs
        store[StorageKeys.enabled] = false
        store[StorageKeys.utmData] = #"[["utm_source","flowbiz"],["utm_journey","16"]]"#
        store[StorageKeys.utmExpiresAtWallMs] = storedExpiry
        let h = CoreHarness(store: store, clock: clock)
        h.core.setPushToken("tok") // persisted, event dropped while disabled

        clock.advance(minuteMs)
        h.core.setEnabled(true)
        let sync = try #require(try h.sentEntries().last { $0["event"] as? String == "push.token.sync" })
        #expect(utm(sync) == #"{"utm_source":"flowbiz","utm_journey":"16"}"#)
        #expect(expiry(store) == storedExpiry)
        h.core.track(.pageView(path: "home"))
        #expect(utm(try h.lastEntry()) == #"{"utm_source":"flowbiz","utm_journey":"16"}"#)
    }

    // MARK: Threading

    /// SPEC §3: UTM work runs on the scheduler, never on the caller's
    /// (typically main) thread. The store is UserDefaults I/O and
    /// `utmContext` is scheduler-confined. With a scheduler that holds its
    /// tasks, neither the startup load (here removing an expired set) nor
    /// a capture touches the store until the scheduler runs them. (The
    /// inline scheduler of the other tests cannot tell the two apart.)
    @Test func startupAndCaptureRunOnTheSchedulerNotOnTheCaller() throws {
        let (url, expected) = try Self.journeyVector()
        let store = FakeKeyValueStore()
        let clock = FakeClock()
        UtmStore(store: store, clock: clock).save([(key: "utm_source", value: "flowbiz")])
        let data = store[StorageKeys.utmData] as? String
        let storedExpiry = expiry(store)
        clock.advance(UtmStore.ttlMillis) // expired: the startup load removes it

        let scheduler = FakeTaskScheduler(inline: false)
        let h = CoreHarness(store: store, clock: clock, scheduler: scheduler)
        #expect(store[StorageKeys.utmData] as? String == data)
        #expect(expiry(store) == storedExpiry)
        scheduler.runPending()
        #expect(store[StorageKeys.utmData] == nil)
        #expect(store[StorageKeys.utmExpiresAtWallMs] == nil)

        h.core.captureUtm(fromLink: url)
        #expect(store[StorageKeys.utmData] == nil)
        scheduler.runPending()
        #expect(expiry(store) == clock.wall + UtmStore.ttlMillis)
        h.core.track(cart)
        scheduler.runPending()
        #expect(bytes(utm(try h.lastEntry())) == bytes(expected))
    }

    // MARK: Ordering on the real serial queue

    /// SPEC §11.1 step 5: `handleLink(url)` then `track(…)` from the same
    /// thread always carries the link's UTMs — the capture is a FIFO task
    /// on the same serial queue the envelope is built on.
    @Test func captureThenTrackIsOrderedOnARealSerialQueue() throws {
        let (url, expected) = try Self.journeyVector()
        let serialQueue = DispatchQueue(label: "br.com.flowbiz.onsite.tests.utm")
        let sender = FakeHttpSender()
        let sent = DispatchSemaphore(value: 0)
        serialQueue.sync { sender.onSend = { _ in sent.signal() } }
        let queue = EventQueue(fileURL: temporaryQueueFile())
        let core = FlowbizCore(
            config: FlowbizConfig(appId: "77777", baseUri: "https://store.com"),
            store: FakeKeyValueStore(),
            queueFactory: { queue },
            sender: sender,
            scheduler: DispatchTaskScheduler(queue: serialQueue),
            clock: FakeClock(),
            deviceContext: DeviceContext(language: "pt-BR", screen: { "1170x2532" }, timezoneOffsetMinutes: { _ in -180 }),
            reachability: FakeReachability()
        )

        core.captureUtm(fromLink: url)
        core.track(cart)

        #expect(sent.wait(timeout: .now() + 5) == .success)
        let body = try #require(serialQueue.sync { sender.bodies.first })
        let root = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let entry = try #require((root["data"] as? [[String: Any]])?.first)
        #expect(entry["event"] as? String == "cart.sync")
        #expect(bytes(utm(entry)) == bytes(expected))
    }
}
#endif
