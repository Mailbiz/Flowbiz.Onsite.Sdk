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
