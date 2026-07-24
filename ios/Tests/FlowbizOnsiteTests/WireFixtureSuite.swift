// Drift-guard tests: every fixture in `shared/fixtures/` is mapped onto the
// typed constructors, serialized, and the produced `data` JSON string is
// structurally compared against `expected.data`. The Kotlin test suite runs
// the exact same fixtures — if the two SDKs disagree, the code is wrong,
// never the fixture.
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct WireFixtureSuite {

    @Test func allFixturesProduceExpectedWirePayload() throws {
        let files = try FixtureSupport.fixtureFiles()
        #expect(!files.isEmpty, "no fixtures found in \(FixtureSupport.fixturesDirectory().path)")

        var failures = [String]()
        for file in files {
            do {
                let fixture = try FixtureSupport.loadFixture(file)
                guard let eventName = fixture["event"] as? String,
                      let expected = fixture["expected"] as? [String: Any],
                      let expectedWireEvent = expected["wire_event"] as? String,
                      let expectedData = expected["data"] as? [String: Any]
                else {
                    failures.append("\(file.lastPathComponent): malformed fixture")
                    continue
                }
                let input = fixture["input"] as? [String: Any] ?? [:]
                let event = try FixtureSupport.buildEvent(eventName, input: input)

                let wireName = EventSerializer.wireName(event)
                if wireName != expectedWireEvent {
                    failures.append("\(file.lastPathComponent): wire_event expected '\(expectedWireEvent)' but was '\(wireName)'")
                }

                // Serialize to the wire string, then parse it back — the wire
                // string is what actually ships.
                let wireString = try EventSerializer.dataJSONString(event)
                guard let wireData = wireString.data(using: .utf8),
                      let produced = try JSONSerialization.jsonObject(with: wireData) as? [String: Any]
                else {
                    failures.append("\(file.lastPathComponent): produced data is not a JSON object: \(wireString)")
                    continue
                }
                if let difference = FixtureSupport.diff(expected: expectedData, actual: produced, path: "data") {
                    failures.append("\(file.lastPathComponent): \(difference)")
                }

                // Byte-for-byte pin of the canonical wire string (sorted
                // keys, JSON.stringify-compatible numbers and escaping) —
                // any future number/escaping divergence fails here.
                guard let canonical = expected["data_canonical"] as? String else {
                    failures.append("\(file.lastPathComponent): missing expected.data_canonical")
                    continue
                }
                if wireString != canonical {
                    failures.append(
                        "\(file.lastPathComponent): canonical wire string mismatch\n"
                            + "  expected: \(canonical)\n  produced: \(wireString)"
                    )
                }
            } catch {
                failures.append("\(file.lastPathComponent): threw \(error)")
            }
        }
        #expect(failures.isEmpty, "fixture mismatches:\n\(failures.joined(separator: "\n"))")
    }

    @Test func fixturesCoverAllTwelveEventTypes() throws {
        var covered = Set<String>()
        for file in try FixtureSupport.fixtureFiles() {
            let fixture = try FixtureSupport.loadFixture(file)
            if let eventName = fixture["event"] as? String { covered.insert(eventName) }
        }
        let all: Set<String> = [
            "pageView", "accountLogin", "accountSync", "productView",
            "cartSync", "addToCart", "cartItemUpdate", "cartSetPostalCode",
            "cartSetCoupon", "checkoutStep", "orderComplete", "orderCancel",
        ]
        #expect(covered == all)
    }

    @Test func fixtureNameMatchesFileName() throws {
        for file in try FixtureSupport.fixtureFiles() {
            let fixture = try FixtureSupport.loadFixture(file)
            let stem = file.deletingPathExtension().lastPathComponent
            #expect(fixture["name"] as? String == stem)
        }
    }

    /// Garbage-input contract, aligned with Kotlin: serialization throws on
    /// non-finite numbers (SPEC §3's never-throw boundary lands in Slice 4).
    @Test func nonFiniteNumbersThrow() {
        for garbage in [Double.nan, .infinity, -.infinity] {
            let event = Event.cartSync(
                cart: Cart(cartId: "c-1", subtotal: garbage, total: 0, freight: 0, tax: 0, discounts: 0)
            )
            #expect(throws: (any Error).self) {
                try EventSerializer.dataJSONString(event)
            }
        }
    }
}
#endif
