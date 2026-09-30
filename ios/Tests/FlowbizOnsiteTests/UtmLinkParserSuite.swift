#if canImport(Testing)
import Foundation
import Testing
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
@testable import FlowbizOnsite

@Suite struct UtmLinkParserSuite {

    static func vectors() throws -> [String: Any] {
        let url = FixtureSupport.sharedDirectory("utm-links").appendingPathComponent("vectors.json")
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func extractVectors() throws -> [[String: Any]] {
        let vectors = try #require(try vectors()["extract"] as? [[String: Any]])
        #expect(vectors.count >= 60, "truncated vectors.json")
        return vectors
    }

    static func extractVector(_ name: String) throws -> (url: String, expected: String) {
        let vector = try #require(try extractVectors().first { $0["name"] as? String == name }, "\(name)")
        return (try #require(vector["url"] as? String), try #require(vector["expected"] as? String))
    }

    // Bytes, not ==: Swift's == is canonical equivalence, so "=\u{338}" would equal "≠".
    static func bytes(_ value: String?) -> [UInt8]? { value.map { Array($0.utf8) } }

    @Test func everyExtractVectorRendersTheWebContextUtm() throws {
        for vector in try Self.extractVectors() {
            let pairs = UtmLinkParser.extract(try #require(vector["url"] as? String))
            let actual = pairs.isEmpty ? nil : CanonicalJSON.renderStringPairs(pairs)
            #expect(Self.bytes(actual) == Self.bytes(vector["expected"] as? String), "\(vector["name"] ?? "?"): \(actual.debugDescription)")
        }
    }

    #if canImport(JavaScriptCore)
    @Test func decoderMatchesAnOracleAndHostileLinksExtractOnlyAllowlistedUtms() throws {
        let context = try #require(JSContext())
        context.evaluateScript("function d(s) { try { return decodeURIComponent(s) } catch (e) { return null } }")
        let decode = try #require(context.objectForKeyedSubscript("d"))
        func check(_ input: String) {
            let result = decode.call(withArguments: [input])
            let web = (result?.isNull ?? true) ? input : result?.toString()
            let port = UtmLinkParser.decodeURIComponentOrRaw(input)
            #expect(Self.bytes(port) == Self.bytes(web), "\(input.debugDescription): port \(port.debugDescription), JS \(web.debugDescription)")
        }
        func escape(_ byte: UInt64) -> String { String(format: "%%%02X", Int(byte & 0xFF)) }
        for first in 0..<256 { check(escape(UInt64(first))) }
        for first in 0x80..<0x100 {
            for second in 0..<256 { check(escape(UInt64(first)) + escape(UInt64(second))) }
        }

        let leads: [UInt64] = [0xC0, 0xC2, 0xDF, 0xE0, 0xE1, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF4, 0xF5, 0xF8]
        let tails: [UInt64] = [0x00, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xFF]
        let raws = [
            "a", "+", " ", "%", "%4", "%g1", "%+F", "é", "😀", "\u{338}", "\u{FEFF}", "|", "=", "&", "?", "#", "/#",
            "utm_source=", "utm_campaign=", "utm_flow_params=", "UTM_SOURCE=",
        ]
        var generator = SplitMix64(seed: 20260923)
        for _ in 0..<5_000 {
            var input = ""
            for _ in 0..<(Int(generator.next() % 6) + 1) {
                switch generator.next() % 4 {
                case 0: input += escape(leads[Int(generator.next() % UInt64(leads.count))])
                case 1: input += escape(tails[Int(generator.next() % UInt64(tails.count))])
                case 2: input += escape(generator.next())
                default: input += raws[Int(generator.next() % UInt64(raws.count))]
                }
            }
            check(input)
            let pairs = UtmLinkParser.extract("https://store.com/?" + input)
            #expect(pairs.map(\.key) == UtmLinkParser.allowlist.filter { key in pairs.contains { $0.key == key } }, "\(input)")
            #expect(pairs.allSatisfy { !$0.value.isEmpty }, "\(input)")
        }
    }
    #endif
}
#endif
