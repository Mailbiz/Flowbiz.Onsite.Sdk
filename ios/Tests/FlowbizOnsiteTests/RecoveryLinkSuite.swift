// `handleLink` decoding (SPEC §11): the `_mb_cr_` + `utm_source` link the
// backend emits, pinned by `shared/recovery-links/vectors.json`.
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

    /// Purity proof (SPEC §3): the public facade decodes with no initialize.
    @Test func facadeDecodesBasicLinkWithoutInitialize() throws {
        let vector = try #require(try Self.vectors().first { ($0["name"] as? String) == "basic" })
        let url = URL(string: try #require(vector["url"] as? String))
        let payload = try #require(Flowbiz.handleLink(url))
        #expect(payload.cartId == "cart-abc-001")
        #expect(payload.products.count == 2)
    }

    @Test func plusTurnedIntoSpaceStillDecodes() throws {
        // Base64 alphabet contains '+'; a naive decoder turns it into ' '.
        let json = #"{"t":"77777","u":"u","c":"c","its":[["1","P>>1","S"]]}"#   // '>' forces a '+' in base64
        let b64 = Data(json.utf8).base64EncodedString()
        #expect(b64.contains("+"))
        let mangled = b64.replacingOccurrences(of: "+", with: " ")
        let link = "https://store.com/c?utm_source=flowbiz&_mb_cr_=\(mangled)"
        #expect(RecoveryLinkParser.parse(link)?.products.first?.productId == "P>>1")
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
