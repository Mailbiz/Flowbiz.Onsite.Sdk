#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct RecoveryLinkSuite {

    static func vectors() throws -> [[String: Any]] {
        let url = FixtureSupport.sharedDirectory("recovery-links").appendingPathComponent("vectors.json")
        let data = try Data(contentsOf: url)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FixtureSupport.FixtureError("vectors.json: root is not an array")
        }
        return array
    }

    @Test func allSharedVectorsDecodeAsExpected() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count >= 20)
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let url = try #require(vector["url"] as? String, "\(name): url")
            let appId = vector["appId"] as? String
            let actual = RecoveryLinkParser.parse(url, expectedAppId: appId)
            if let expected = vector["expected"] as? [String: Any] {
                let payload = try #require(actual, "\(name): expected a payload")
                #expect(payload == (try Self.payload(expected)), "\(name)")
            } else {
                #expect(actual == nil, "\(name): expected nil")
            }
        }
    }

    @Test func facadeDecodesBasicLinkWithoutInitialize() throws {
        let vector = try #require(try Self.vectors().first { ($0["name"] as? String) == "basic" })
        let url = URL(string: try #require(vector["url"] as? String))
        let payload = try #require(Flowbiz.handleLink(url))
        #expect(payload.cartId == "cart-abc-001")
        #expect(payload.products.count == 2)
    }

    @Test func plusTurnedIntoSpaceStillDecodes() throws {
        let json = #"{"t":"77777","u":"u","c":"c","its":[["1","P>>1","S"]]}"#
        let b64 = Data(json.utf8).base64EncodedString()
        #expect(b64.contains("+"))
        let mangled = b64.replacingOccurrences(of: "+", with: " ")
        let link = "https://store.com/c?utm_source=flowbiz&_mb_cr_=\(mangled)"
        #expect(RecoveryLinkParser.parse(link)?.products.first?.productId == "P>>1")
    }

    @Test func adversarialDecodedHashesNeverThrow() {
        var generator = SplitMix64(seed: 20260902)
        for _ in 0..<300 {
            let hash = Self.randomHash(&generator)
            guard let data = try? JSONSerialization.data(withJSONObject: hash) else { continue }
            let b64 = data.base64EncodedString()
            let url = "https://store.com/c?utm_source=flowbiz&_mb_cr_=\(b64)"
            _ = RecoveryLinkParser.parse(url, expectedAppId: "77777")
        }
    }

    private static func randomHash(_ gen: inout SplitMix64) -> [String: Any] {
        ["t": randomField(&gen), "u": randomField(&gen), "c": randomField(&gen), "its": randomIts(&gen)]
    }

    private static func randomField(_ gen: inout SplitMix64) -> Any {
        switch gen.next() % 5 {
        case 0: return "field-\(gen.next() % 1000)"
        case 1: return gen.next() % 100_000
        case 2: return gen.next() % 2 == 0
        case 3: return NSNull()
        default: return ""
        }
    }

    private static func randomIts(_ gen: inout SplitMix64) -> Any {
        switch gen.next() % 6 {
        case 0: return NSNull()
        case 1: return "not an array"
        case 2: return gen.next() % 1000
        case 3: return ["k": "v"]
        case 4: return []
        default:
            var items = [Any]()
            let count = Int(gen.next() % 4) + 1
            for _ in 0..<count { items.append(randomItem(&gen)) }
            return items
        }
    }

    private static func randomItem(_ gen: inout SplitMix64) -> Any {
        if gen.next() % 4 == 0 { return randomSlot(&gen) }
        var item = [Any]()
        let slotCount = Int(gen.next() % 5)
        for _ in 0..<slotCount { item.append(randomSlot(&gen)) }
        return item
    }

    private static func randomSlot(_ gen: inout SplitMix64) -> Any {
        switch gen.next() % 9 {
        case 0: return 1e30
        case 1: return -1e30
        case 2: return 1e308
        case 3: return gen.next() % 2 == 0
        case 4: return NSNull()
        case 5: return ["nested": "object"]
        case 6:
            var value: Any = ["leaf"]
            for _ in 0..<20 { value = [value] }
            return value
        case 7: return ""
        default: return String(repeating: "x", count: 10_000)
        }
    }

    @Test func nilAndGarbageNeverThrow() {
        #expect(Flowbiz.handleLink(nil) == nil)
        #expect(RecoveryLinkParser.parse("") == nil)
        #expect(RecoveryLinkParser.parse("?&&=&_mb_cr_&utm_source") == nil)
    }

    private static func payload(_ json: [String: Any]) throws -> RecoveryPayload {
        let products = try (json["products"] as? [[String: Any]] ?? []).map { item -> RecoveryProduct in
            var properties: [String: JSONValue]? = nil
            if let raw = item["recoveryProperties"] as? [String: Any] {
                properties = JSONValue.objectFromFoundation(raw)
            }
            return RecoveryProduct(
                productId: try #require(item["productId"] as? String),
                sku: try #require(item["sku"] as? String),
                quantity: try #require(item["quantity"] as? Int),
                recoveryProperties: properties
            )
        }
        return RecoveryPayload(
            cartId: try #require(json["cartId"] as? String),
            userId: try #require(json["userId"] as? String),
            products: products
        )
    }
}
#endif
