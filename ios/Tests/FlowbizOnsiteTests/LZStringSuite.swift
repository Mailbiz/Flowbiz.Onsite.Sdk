// The LZ-string decompressor port, pinned against the real JS library
// (SPEC §11/§14): `shared/lzstring-vectors/vectors.json` was generated with
// lz-string 1.4.4 under node — including the garbage cases, whose expected
// outputs (`""` vs null) are the library's actual behavior.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct LZStringSuite {

    static func vectors() throws -> [[String: Any]] {
        let url = FixtureSupport.sharedDirectory("lzstring-vectors")
            .appendingPathComponent("vectors.json")
        let data = try Data(contentsOf: url)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FixtureSupport.FixtureError("vectors.json: root is not an array of objects")
        }
        return array
    }

    @Test func allSharedVectorsDecodeIdenticallyToTheReferenceLibrary() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count >= 12, "vector file must not be empty")
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let compressed = vector["compressed"] as? String ?? ""
            let actual = LZString.decompressFromEncodedURIComponent(compressed)
            if vector["expect_null"] as? Bool == true {
                #expect(actual == nil, "vector '\(name)' must decode to nil")
            } else {
                let expected = vector["expected_decompressed"] as? String
                #expect(actual == expected, "vector '\(name)'")
            }
        }
    }

    @Test func nilAndEmptyInputAreNil() {
        #expect(LZString.decompressFromEncodedURIComponent(nil) == nil)
        #expect(LZString.decompressFromEncodedURIComponent("") == nil)
    }

    /// Never-throw fuzz: random garbage must produce a value or nil, not a crash.
    @Test func randomGarbageNeverCrashes() {
        var generator = SplitMix64(seed: 20_260_724)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-$")
        for _ in 0..<500 {
            let length = Int(generator.next() % 120)
            var garbage = ""
            for _ in 0..<length {
                switch generator.next() % 4 {
                case 0: garbage.append(alphabet[Int(generator.next() % UInt64(alphabet.count))])
                case 1: garbage.append(Character(UnicodeScalar(UInt8(32 + generator.next() % 95))))
                case 2:
                    if let scalar = UnicodeScalar(UInt32(0x20 + generator.next() % 0xD780)) {
                        garbage.append(Character(scalar))
                    }
                default: garbage.append(" ")
                }
            }
            _ = LZString.decompressFromEncodedURIComponent(garbage) // must not crash
        }
    }
}

/// Tiny deterministic PRNG for the fuzz tests (seeded, reproducible).
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
