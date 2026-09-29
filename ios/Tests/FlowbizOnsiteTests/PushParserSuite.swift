// Through the public facade: `handlePush` is pure and needs no initialize.
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

    @Test func wellFormedDeepLinkBecomesAURL() {
        let push = Flowbiz.handlePush(
            ["flowbiz": #"{"v":1,"type":"promo","deep_link":"https://store.com/promo"}"#]
        )
        #expect(push?.deepLink == URL(string: "https://store.com/promo"))
    }

    /// The raw `deep_link` is kept for `handlePushOpened`; on iOS 17+ (this
    /// host) `deepLink` is plain `URL(string:)` of it.
    @Test func deepLinkIsURLParsingOfTheKeptRawString() throws {
        for link in [
            "https://store.com/carrinho?utm_campaign=jornadas|cart|x&utm_medium=e%20mail",
            "myapp:cart?utm_source=flowbiz&utm_journey_type=1#promo",
            "https://café.com/promo?utm_source=flowbiz",
            "//sto|re.com/p",
        ] {
            let marker = try JSONSerialization.data(withJSONObject: ["v": 1, "type": "promo", "deep_link": link])
            let push = try #require(Flowbiz.handlePush(["flowbiz": String(decoding: marker, as: UTF8.self)]), "\(link)")
            #expect(push.deepLinkString == link, "\(link)")
            #expect(push.deepLink == URL(string: link), "\(link)")
        }
    }

    /// Stands in for iOS 13–16's `URL(string:)`, which rejects any character
    /// outside RFC 3986 (iOS 17+ encodes them itself).
    private static func legacyParse(_ string: String) -> URL? {
        CFURLCreateWithString(nil, string as CFString, nil).map { $0 as URL }
    }

    /// A link the iOS 13–16 parser accepts is kept as is; a rejected one gets
    /// only its non-RFC 3986 characters encoded after `scheme://authority`,
    /// so its UTMs and `_mb_cr_` read the same. What encoding cannot repair
    /// (a non-ASCII or invalid host, a bare `%`, no scheme) stays nil.
    @Test func iOS13To16RepairEncodesOnlyInvalidCharactersAfterTheAuthority() throws {
        var cases: [(raw: String, repaired: String?)] = [
            ("https://store.com/p?utm_campaign=jornadas%7Ccart%7Cx#top", "https://store.com/p?utm_campaign=jornadas%7Ccart%7Cx#top"),
            ("https://store.com/busca?q=camisa azul&utm_source=flowbiz", "https://store.com/busca?q=camisa%20azul&utm_source=flowbiz"),
            ("https://store.com/p?utm_campaign=promoção&utm_medium=e%20mail", "https://store.com/p?utm_campaign=promo%C3%A7%C3%A3o&utm_medium=e%20mail"),
            ("https://store.com/p?utm_content=\"x\"<y>{z}^`\\&utm_source=a|b",
             "https://store.com/p?utm_content=%22x%22%3Cy%3E%7Bz%7D%5E%60%5C&utm_source=a%7Cb"),
            ("https://user@store.com:8443/c/ação?utm_source=a|b#topo", "https://user@store.com:8443/c/a%C3%A7%C3%A3o?utm_source=a%7Cb#topo"),
            ("https://store.com/busca?filter[cor]=azul&utm_campaign=a|b", "https://store.com/busca?filter%5Bcor%5D=azul&utm_campaign=a%7Cb"),
            ("https://store.com?utm_source=a|b", "https://store.com?utm_source=a%7Cb"),
            ("https://store.com#x|y", "https://store.com#x%7Cy"),
            ("https://store.com/\u{338}?utm_source=a|b", "https://store.com/%CC%B8?utm_source=a%7Cb"),
            ("https:/\u{338}/café.com/p?utm_source=a|b", "https:/%CC%B8/caf%C3%A9.com/p?utm_source=a%7Cb"),
            ("myapp:ç|x", "myapp:%C3%A7%7Cx"),
            ("myapp:open?next=https://café.com|x", "myapp:open?next=https://caf%C3%A9.com%7Cx"),
            ("https://café.com/p?utm_source=a|b", nil),
            ("https://\u{338}café.com/p?utm_source=a|b", nil),
            ("https://store com/p?utm_source=a|b", nil),
            ("https://store.com/p?utm_campaign=50%|x", nil),
            ("//café.com/p?utm_source=a|b", nil),
            (" https://store.com/p?utm_source=a|b", nil),
            ("1app://store.com/p?utm_source=a|b", nil),
        ]
        for vector in try UtmLinkParserSuite.extractVectors() where (vector["name"] as? String)?.hasPrefix("messagebuilder_") == true {
            let raw = try #require(vector["url"] as? String)
            cases.append((raw, raw.replacingOccurrences(of: "|", with: "%7C")))
        }
        for (raw, repaired) in cases {
            let url = PushPayloadParser.deepLinkURL(raw, parse: Self.legacyParse)
            #expect(url?.absoluteString == repaired, "\(raw)")
            if let url {
                #expect(UtmLinkParser.extract(url.absoluteString).map(\.value) == UtmLinkParser.extract(raw).map(\.value), "\(raw)")
                #expect(RecoveryLinkParser.parse(url.absoluteString) == RecoveryLinkParser.parse(raw), "\(raw)")
            }
        }
    }

    @Test func iOS13To16RepairNeverTrapsNorTouchesTheHost() {
        var generator = SplitMix64(seed: 13)
        let alphabet = Array("ab09:/?#[]@!$&'()*+,;=%|\" <>{}^`\\çã€😀\u{338}\t")
        let prefixes = ["https://store.com/", "myapp:", "myapp://h/", "", "//", "//café.com/", " https://", "1app://h/", "https://"]
        for _ in 0..<2_000 {
            var raw = prefixes[Int(generator.next() % UInt64(prefixes.count))]
            for _ in 0..<(generator.next() % 40) {
                raw.append(alphabet[Int(generator.next() % UInt64(alphabet.count))])
            }
            if Self.legacyParse(raw) == nil, let host = PushPayloadParser.deepLinkURL(raw, parse: Self.legacyParse)?.host {
                #expect(!host.contains("%") && host.unicodeScalars.allSatisfy(\.isASCII), "\(raw) → \(host)")
            }
            _ = PushPayloadParser.deepLinkURL(raw)
        }
    }

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
            _ = Flowbiz.handlePush(["flowbiz": garbage])
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
