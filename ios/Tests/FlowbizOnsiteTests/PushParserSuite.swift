// `handlePush` (SPEC §10.2/§10.3) driven by the shared drift-guard samples
// (`shared/push-samples/samples.json`). Samples are exercised through the
// public facade — `handlePush` is pure and requires no initialize (SPEC §3).
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct PushParserSuite {

    static func samples() throws -> [[String: Any]] {
        let url = FixtureSupport.sharedDirectory("push-samples")
            .appendingPathComponent("samples.json")
        let data = try Data(contentsOf: url)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FixtureSupport.FixtureError("samples.json: root is not an array of objects")
        }
        return array
    }

    @Test func allSharedSamplesParseAsExpected() throws {
        for sample in try Self.samples() {
            let name = sample["name"] as? String ?? "?"
            let payload = sample["payload"] as? [String: Any] ?? [:]
            // iOS override first (the dict-marker sample parses here, unlike Android).
            let expected = sample["expected_ios"] ?? sample["expected"]
            let push = Flowbiz.handlePush(payload)
            if expected == nil || expected is NSNull {
                #expect(push == nil, "sample '\(name)' must be nil")
            } else {
                let expectedPush = try #require(expected as? [String: Any], "sample '\(name)': bad expected")
                let actual = try #require(push, "sample '\(name)' must parse")
                assertPushMatches(name, expected: expectedPush, push: actual)
            }
            if let expectedRecovery = sample["expected_recovery"] as? [String: Any] {
                let actual = try #require(push?.recoveryPayload, "sample '\(name)': recoveryPayload")
                try assertRecoveryMatches(name, expected: expectedRecovery, recovery: actual)
            }
        }
    }

    private func assertPushMatches(_ name: String, expected: [String: Any], push: FlowbizPush) {
        #expect(push.version == (expected["version"] as? Int ?? -1), "\(name): version")
        #expect(push.type == expected["type"] as? String, "\(name): type")
        #expect(push.title == stringOrNil(expected["title"]), "\(name): title")
        #expect(push.body == stringOrNil(expected["body"]), "\(name): body")
        #expect(push.deepLinkString == stringOrNil(expected["deepLink"]), "\(name): deepLink")
        let expectedData = (expected["data"] as? [String: Any]).flatMap(JSONValue.objectFromFoundation) ?? [:]
        #expect(push.data == expectedData, "\(name): data")
    }

    private func assertRecoveryMatches(_ name: String, expected: [String: Any], recovery: RecoveryPayload) throws {
        #expect(recovery.cartId == expected["cartId"] as? String, "\(name): cartId")
        #expect(recovery.userId == expected["userId"] as? String, "\(name): userId")
        let products = expected["products"] as? [[String: Any]] ?? []
        #expect(recovery.products.count == products.count, "\(name): product count")
        for (index, expectedProduct) in products.enumerated() where index < recovery.products.count {
            let product = recovery.products[index]
            #expect(product.productId == expectedProduct["productId"] as? String)
            #expect(product.sku == expectedProduct["sku"] as? String)
            #expect(product.quantity == expectedProduct["quantity"] as? Int)
            if expectedProduct["recoveryProperties"] is NSNull || expectedProduct["recoveryProperties"] == nil {
                #expect(product.recoveryProperties == nil)
            } else {
                let expectedProperties = (expectedProduct["recoveryProperties"] as? [String: Any])
                    .flatMap(JSONValue.objectFromFoundation)
                #expect(product.recoveryProperties == expectedProperties)
            }
        }
    }

    private func stringOrNil(_ value: Any?) -> String? {
        value is NSNull ? nil : value as? String
    }

    // MARK: contract details beyond the shared samples

    /// A well-formed `deep_link` surfaces as both the raw string and a URL.
    @Test func wellFormedDeepLinkBecomesAURL() {
        let push = Flowbiz.handlePush(
            ["flowbiz": #"{"v":1,"type":"promo","deep_link":"https://store.com/promo"}"#]
        )
        #expect(push?.deepLink == URL(string: "https://store.com/promo"))
    }

    /// `deepLink` is for routing: on iOS 17+ (this host) exactly
    /// `URL(string:)` over `deep_link`, whatever Foundation makes of it (the
    /// iOS 13–16 repair of links it rejects is pinned below). The raw string
    /// is kept alongside it for `recoveryPayload` and
    /// `Flowbiz.handlePushOpened`, which read the link exactly as delivered
    /// (SPEC §10.2, §11.1). The capture side is pinned in
    /// `FlowbizCoreUtmSuite`.
    @Test func deepLinkIsPlainURLParsingOfTheRawString() throws {
        for link in [
            "https://store.com/carrinho?utm_campaign=jornadas|cart|carrinho-abandonado&utm_medium=e%20mail",
            "myapp:cart?utm_source=flowbiz&utm_journey_type=1#promo",
            "https://café.com/promo?utm_source=flowbiz",
        ] {
            let marker = try #require(String(
                data: try JSONSerialization.data(withJSONObject: ["v": 1, "type": "promo", "deep_link": link] as [String: Any]),
                encoding: .utf8
            ))
            let push = try #require(Flowbiz.handlePush(["flowbiz": marker]), "\(link)")
            #expect(push.deepLinkString == link, "\(link)")
            #expect(push.deepLink == URL(string: link), "\(link)")
        }
    }

    // MARK: deepLink on iOS 13–16

    /// iOS 13–16's `URL(string:)` is the legacy CFURL parser: it rejects any
    /// character outside RFC 3986. `CFURLCreateWithString` is that parser on
    /// every OS, so it stands in for iOS 13–16 here. (iOS 17+'s
    /// `URL(string:)` — this host's — encodes such characters itself and
    /// never needs the repair.)
    private static func legacyParse(_ string: String) -> URL? {
        CFURLCreateWithString(nil, string as CFString, nil).map { $0 as URL }
    }

    /// MessageBuilder writes the campaign's `|` raw. On iOS 13–16 that made
    /// `deepLink` nil; the repaired URL now routes and keeps the raw link's
    /// UTMs and recovery hash, so even `handleLink(push.deepLink)` agrees
    /// with `handlePushOpened` (SPEC §10.2).
    @Test func iOS13To16RoutesMessageBuilderLinksWithRawPipes() throws {
        let extract = try #require(UtmLinkParserSuite.vectors()["extract"] as? [[String: Any]])
        let links = extract.filter { ($0["name"] as? String)?.hasPrefix("messagebuilder_") == true }
        #expect(links.count >= 4)
        for vector in links {
            let raw = try #require(vector["url"] as? String)
            #expect(Self.legacyParse(raw) == nil, "\(raw): precondition — rejected on iOS 13–16")
            let url = try #require(PushPayloadParser.deepLinkURL(raw, parse: Self.legacyParse), "\(raw)")
            #expect(url.absoluteString == raw.replacingOccurrences(of: "|", with: "%7C"))
            #expect(UtmLinkParser.render(UtmLinkParser.extract(url.absoluteString)) == vector["expected"] as? String)
            let recovery = RecoveryLinkParser.parse(url.absoluteString, expectedAppId: "77777")
            #expect(recovery != nil && recovery == RecoveryLinkParser.parse(raw, expectedAppId: "77777"))
        }
    }

    /// Only characters outside RFC 3986 are encoded, and only after the
    /// authority: existing escapes and every delimiter are kept, so the
    /// query — and its UTMs — read the same as the raw link's.
    @Test func iOS13To16EncodesOnlyInvalidCharacters() throws {
        let cases: [(raw: String, expected: String)] = [
            ("https://store.com/busca?q=camisa azul&utm_source=flowbiz",
             "https://store.com/busca?q=camisa%20azul&utm_source=flowbiz"),
            ("https://store.com/p?utm_campaign=promoção&utm_medium=e%20mail",
             "https://store.com/p?utm_campaign=promo%C3%A7%C3%A3o&utm_medium=e%20mail"),
            ("https://store.com/p?utm_content=\"x\"<y>{z}^`\\&utm_source=a|b",
             "https://store.com/p?utm_content=%22x%22%3Cy%3E%7Bz%7D%5E%60%5C&utm_source=a%7Cb"),
            ("https://user@store.com:8443/c/ação?utm_source=a|b#topo",
             "https://user@store.com:8443/c/a%C3%A7%C3%A3o?utm_source=a%7Cb#topo"),
            ("myapp:cart?utm_source=a|b", "myapp:cart?utm_source=a%7Cb"),
            ("myapp://open?next=https://x.com/a|b&utm_source=a|b",
             "myapp://open?next=https://x.com/a%7Cb&utm_source=a%7Cb"),
            ("myapp:open?next=https://x.com/a|b", "myapp:open?next=https://x.com/a%7Cb"),
            // The authority ends at `?` or `#` as well as `/`.
            ("https://store.com?utm_source=a|b", "https://store.com?utm_source=a%7Cb"),
            ("https://store.com#x|y", "https://store.com#x%7Cy"),
            // A combining mark right after the authority's `/` is path, not host.
            ("https://store.com/\u{338}?utm_source=a|b", "https://store.com/%CC%B8?utm_source=a%7Cb"),
        ]
        for (raw, expected) in cases {
            #expect(Self.legacyParse(raw) == nil, "\(raw): precondition — rejected on iOS 13–16")
            let url = PushPayloadParser.deepLinkURL(raw, parse: Self.legacyParse)
            #expect(url?.absoluteString == expected, "\(raw)")
            #expect(url.map { UtmLinkParser.extract($0.absoluteString).map(\.value) } == UtmLinkParser.extract(raw).map(\.value), "\(raw)")
        }
    }

    /// What percent-encoding cannot repair stays nil on iOS 13–16, as
    /// before: a non-ASCII host needs IDNA (encoding it would name another
    /// host), a bare `%` or a second `#` is not an invalid character, and a
    /// link without a scheme (`//host…`, a leading space or BOM, a scheme
    /// starting with a digit) is not an absolute link to repair.
    @Test func iOS13To16LeavesUnrepairableLinksNil() {
        for raw in [
            "https://café.com/p?utm_source=a|b",
            "https://store com/p?utm_source=a|b",
            "https://\u{338}café.com/p?utm_source=a|b",
            "https://store.com/p?utm_campaign=50%|x",
            "https://store.com/#/cart?utm_source=a|b#x",
            "//café.com/p?utm_source=a|b",
            "//sto|re.com/p",
            " https://store.com/p?utm_source=a|b",
            "\u{FEFF}https://store.com/p?utm_source=a|b",
            "1app://store.com/p?utm_source=a|b",
            "://store com/p",
        ] {
            #expect(PushPayloadParser.deepLinkURL(raw, parse: Self.legacyParse) == nil, "\(raw)")
        }
        // A combining mark after `:/` is no `//` — the link has no authority,
        // and the repair yields a host-less path, never a percent-encoded
        // host. (Right after `//` it opens the authority, see above.)
        let unglued = PushPayloadParser.deepLinkURL("https:/\u{338}/café.com/p?utm_source=a|b", parse: Self.legacyParse)
        #expect(unglued != nil && unglued?.host == nil)
    }

    /// iOS 13–16's parser accepts `[`/`]` anywhere (RFC 2732 IPv6
    /// support), so a bracketed query only needs its other invalid
    /// characters repaired.
    @Test func iOS13To16RoutesBracketedQueries() throws {
        let raw = "https://store.com/busca?filter[cor]=azul&utm_campaign=jornadas|cart|x"
        let url = try #require(PushPayloadParser.deepLinkURL(raw, parse: Self.legacyParse))
        #expect(url.host == "store.com")
        #expect(UtmLinkParser.extract(url.absoluteString).map(\.value) == UtmLinkParser.extract(raw).map(\.value))
    }

    /// The repair never touches `scheme://authority`: a host needing IDNA
    /// (or holding any other invalid character) makes it give up rather
    /// than percent-encode a different host name — whatever the parser
    /// would then make of it.
    @Test func repairNeverEncodesTheAuthority() {
        #expect(PushPayloadParser.encodingInvalidCharacters("https://café.com/p?utm_source=a|b") == nil)
        #expect(PushPayloadParser.encodingInvalidCharacters("https://store com/p?utm_source=a|b") == nil)
        // Scalars, not Characters: a combining mark right after `//` is the
        // first scalar of the host (a Character scan would glue it onto `/`).
        #expect(PushPayloadParser.encodingInvalidCharacters("https://\u{338}café.com/p?utm_source=a|b") == nil)
        // No scheme, no repair: `//host` would otherwise be encoded as path.
        #expect(PushPayloadParser.encodingInvalidCharacters("//café.com/p?utm_source=a|b") == nil)
        #expect(PushPayloadParser.encodingInvalidCharacters(" https://store.com/p|") == nil)
        #expect(PushPayloadParser.encodingInvalidCharacters("https://user@store.com:8443/ç?a=b|c#f")
            == "https://user@store.com:8443/%C3%A7?a=b%7Cc#f")
        #expect(PushPayloadParser.encodingInvalidCharacters("myapp:ç|x") == "myapp:%C3%A7%7Cx")
        #expect(PushPayloadParser.encodingInvalidCharacters("myapp:open?next=https://café.com")
            == "myapp:open?next=https://caf%C3%A9.com")
    }

    /// A link the parser accepts is returned exactly as parsed — the repair
    /// never runs. On iOS 17+ (this host's `URL(string:)`) that is every
    /// link above, so `deepLink` is unchanged there.
    @Test func parsedLinksAreNeverRepaired() {
        for raw in [
            "https://store.com/p?utm_campaign=jornadas%7Ccart%7Cx&_mb_cr_=eyJ0Ijo+/=",
            "https://store.com/busca?q=cal%E7a&utm_campaign=promo%FF#top",
            "myapp:cart?utm_source=flowbiz#promo",
        ] {
            #expect(PushPayloadParser.deepLinkURL(raw, parse: Self.legacyParse) == Self.legacyParse(raw), "\(raw)")
        }
        for raw in [
            "https://store.com/carrinho?utm_campaign=jornadas|cart|x",
            "https://café.com/promo?utm_source=flowbiz",
            "https://store.com/p?q=a%20b&x={y}",
            "myapp:cart?utm_source=flowbiz&utm_journey_type=1#promo",
            // Rejected here too (no scheme): still nil, not repaired.
            "//sto|re.com/p",
            "//store com/carrinho?utm_campaign=a|b",
            "://store com/p",
            " https://store.com/p?utm_source=a|b",
        ] {
            #expect(PushPayloadParser.deepLinkURL(raw) == URL(string: raw), "\(raw)")
        }
    }

    @Test func deepLinkRepairNeverTraps() {
        var generator = SplitMix64(seed: 13)
        let alphabet = Array("ab09:/?#[]@!$&'()*+,;=%|\" <>{}^`\\çã€😀\u{338}\t")
        for _ in 0..<2_000 {
            let prefixes = ["https://store.com/", "myapp:", "myapp://h/", "", "//", "//café.com/", " https://", "1app://h/", "https://"]
            var raw = prefixes[Int(generator.next() % UInt64(prefixes.count))]
            for _ in 0..<(generator.next() % 40) {
                raw.append(alphabet[Int(generator.next() % UInt64(alphabet.count))])
            }
            // A repair percent-encodes after the authority only: whatever
            // host a repaired URL has came through untouched.
            if Self.legacyParse(raw) == nil, let host = PushPayloadParser.deepLinkURL(raw, parse: Self.legacyParse)?.host {
                #expect(!host.contains("%") && host.unicodeScalars.allSatisfy(\.isASCII), "\(raw) → \(host)")
            }
            _ = PushPayloadParser.deepLinkURL(raw)
        }
    }

    /// SPEC §3 purity: no initialize needed, nil/empty payloads are nil.
    @Test func nilAndEmptyPayloadsAreNil() {
        #expect(Flowbiz.handlePush(nil) == nil)
        #expect(Flowbiz.handlePush([:]) == nil)
        #expect(Flowbiz.handlePush(["flowbiz": 42]) == nil) // non-string, non-dict marker
    }

    @Test func randomGarbageMarkerNeverCrashes() {
        var generator = SplitMix64(seed: 7)
        for _ in 0..<300 {
            var garbage = ""
            for _ in 0..<(generator.next() % 80) {
                if let scalar = UnicodeScalar(UInt32(0x20 + generator.next() % 0x2FDF)) {
                    garbage.unicodeScalars.append(scalar)
                }
            }
            _ = Flowbiz.handlePush(["flowbiz": garbage]) // must not crash
        }
    }
}

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
