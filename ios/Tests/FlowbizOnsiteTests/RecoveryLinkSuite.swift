// `handleLink` decoding (SPEC §11) — exercised through the public facade
// (pure, no initialize needed) and the string-level parser. Compressed
// inputs come from `shared/lzstring-vectors/vectors.json`, generated with
// the real lz-string library — links built here are byte-identical to
// web-generated ones.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct RecoveryLinkSuite {

    static let vectors: [String: String] = {
        guard let array = try? LZStringSuite.vectors() else { return [:] }
        var result = [String: String]()
        for vector in array {
            if let name = vector["name"] as? String, let compressed = vector["compressed"] as? String {
                result[name] = compressed
            }
        }
        return result
    }()

    private func vector(_ name: String) throws -> String {
        guard let compressed = Self.vectors[name] else {
            throw FixtureSupport.FixtureError("missing vector '\(name)'")
        }
        return compressed
    }

    private func link(_ compressed: String) -> String {
        "https://store.com/recover?utm_source=flowbiz&mb_recovery=\(compressed)"
    }

    // MARK: end-to-end against real web-generated compressed hashes

    /// Purity proof (SPEC §3): the public facade decodes with no initialize.
    @Test func facadeDecodesRealCompressedBasicHashWithoutInitialize() throws {
        let url = URL(string: link(try vector("recovery_hash_basic")))
        let payload = try #require(Flowbiz.handleLink(url))
        #expect(payload.cartId == "cart-abc-001")
        #expect(payload.userId == "user-123")
        #expect(payload.products == [
            RecoveryProduct(productId: "P100", sku: "SKU-100-P", quantity: 2, recoveryProperties: nil),
            RecoveryProduct(productId: "P200", sku: "SKU-200-M", quantity: 1, recoveryProperties: nil),
        ])
    }

    @Test func decodesRecoveryPropertiesFromJsonStringElement() throws {
        let payload = try #require(RecoveryLinkParser.parse(link(try vector("recovery_hash_with_recovery_properties"))))
        #expect(payload.cartId == "cart-77-xyz")
        #expect(payload.userId == "u-9f2c")
        #expect(payload.products[0].quantity == 3)
        #expect(payload.products[0].recoveryProperties == [
            "cor": "Azul Marinho", "tamanho": "P", "seller": "loja-1",
        ])
        #expect(payload.products[1].recoveryProperties == ["cor": "Verde", "tamanho": "GG"])
    }

    @Test func decodesUnicodeProductData() throws {
        let payload = try #require(RecoveryLinkParser.parse(link(try vector("recovery_hash_unicode_product_data"))))
        #expect(payload.userId == "maria@exemplo.com.br")
        #expect(payload.products[0].productId == "CAMISETA-AÇAÍ")
        #expect(payload.products[0].recoveryProperties?["nome"] == "Camiseta Açaí 🛒")
        #expect(payload.products[0].recoveryProperties?["descrição"] == "Tamanho médio — çãõ")
    }

    @Test func decodesLongCart() throws {
        let payload = try #require(RecoveryLinkParser.parse(link(try vector("recovery_hash_long_cart_25_items"))))
        #expect(payload.products.count == 25)
        #expect(payload.products[0].productId == "PROD-1000")
        #expect(payload.products[24].productId == "PROD-1024")
        #expect(payload.products[0].recoveryProperties?["estoque"] == 10)
    }

    /// Web `parseInt(it[0]) || 1` semantics: "0" → 1, "abc" → 1, missing fields → "".
    @Test func quantityAndFieldFallbacksMatchWebSemantics() throws {
        let payload = try #require(RecoveryLinkParser.parse(link(try vector("recovery_hash_quantity_edge_cases"))))
        let products = payload.products
        #expect(products.count == 4)
        #expect(products[0].quantity == 1) // "0" is falsy in JS -> 1
        #expect(products[1].quantity == 1) // "abc" -> NaN -> 1
        #expect(products[2].quantity == 4)
        #expect(products[2].productId == "") // missing -> ""
        #expect(products[2].sku == "")
        #expect(products[3].quantity == 2)
        #expect(products[3].recoveryProperties == nil) // "{not json" -> nil
    }

    // MARK: URL-encoding tolerance

    @Test func percentEncodedValueDecodes() throws {
        let compressed = try vector("recovery_hash_basic")
        let encoded = compressed
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "$", with: "%24")
        #expect(RecoveryLinkParser.parse(link(encoded)) == RecoveryLinkParser.parse(link(compressed)))
        #expect(RecoveryLinkParser.parse(link(encoded)) != nil)
    }

    @Test func plusTurnedIntoSpaceStillDecodes() throws {
        // A naive URL decoder turns '+' into ' '; the decompressor restores it.
        let compressed = try vector("recovery_hash_basic")
        let mangled = compressed.replacingOccurrences(of: "+", with: " ")
        #expect(RecoveryLinkParser.parse(link(mangled)) == RecoveryLinkParser.parse(link(compressed)))
    }

    @Test func parameterIsFoundAmongOthersAndBeforeFragment() throws {
        let compressed = try vector("recovery_hash_basic")
        let url = "https://store.com/p?a=1&mb_recovery=\(compressed)&b=2#section"
        #expect(RecoveryLinkParser.parse(url) != nil)
    }

    // MARK: nil paths

    @Test func missingParameterIsNil() {
        #expect(Flowbiz.handleLink(URL(string: "https://store.com/recover")) == nil)
        #expect(Flowbiz.handleLink(URL(string: "https://store.com/recover?utm_source=flowbiz")) == nil)
        #expect(Flowbiz.handleLink(URL(string: "https://store.com/recover?mb_recovery=")) == nil)
        #expect(Flowbiz.handleLink(nil) == nil)
    }

    @Test func undecodableValueIsNil() {
        #expect(RecoveryLinkParser.parse(link("!!!not-compressed!!!")) == nil)
    }

    /// Web validation parity: t, u and c must be present and non-empty, its non-empty.
    @Test func invalidHashShapesAreNilWholePayload() throws {
        for name in [
            "invalid_hash_missing_u",
            "invalid_hash_empty_c",
            "invalid_hash_empty_its",
            "invalid_hash_its_not_array",
            "invalid_hash_not_json",
        ] {
            #expect(RecoveryLinkParser.parse(link(try vector(name))) == nil, "vector '\(name)' must map to nil")
        }
    }

    /// Never-throw fuzz over whole URLs.
    @Test func randomGarbageUrlsNeverCrash() {
        var generator = SplitMix64(seed: 42)
        for _ in 0..<300 {
            var garbage = "https://x.com/?mb_recovery="
            for _ in 0..<(generator.next() % 60) {
                if let scalar = UnicodeScalar(UInt32(0x20 + generator.next() % 0x2FDF)) {
                    garbage.unicodeScalars.append(scalar)
                }
            }
            _ = RecoveryLinkParser.parse(garbage) // must not crash
            _ = Flowbiz.handleLink(URL(string: garbage))
        }
    }
}
#endif
