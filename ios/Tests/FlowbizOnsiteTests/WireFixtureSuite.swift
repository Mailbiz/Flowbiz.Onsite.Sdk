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
                      let expectedWireEvent = expected["wire_event"] as? String
                else {
                    failures.append("\(file.lastPathComponent): malformed fixture")
                    continue
                }
                let input = fixture["input"] as? [String: Any] ?? [:]
                let dropped = expected["dropped"] as? Bool ?? false
                let sanitized = UserSanitizer.sanitize(try FixtureSupport.buildEvent(eventName, input: input))
                guard let event = sanitized, !dropped else {
                    if (sanitized == nil) != dropped {
                        failures.append("\(file.lastPathComponent): expected dropped=\(dropped)")
                    }
                    continue
                }
                guard let expectedData = expected["data"] as? [String: Any] else {
                    failures.append("\(file.lastPathComponent): malformed fixture")
                    continue
                }
                let baseUri = fixture["baseUri"] as? String

                let wireName = EventSerializer.wireName(event)
                if wireName != expectedWireEvent {
                    failures.append("\(file.lastPathComponent): wire_event expected '\(expectedWireEvent)' but was '\(wireName)'")
                }

                let wireString = try EventSerializer.dataJSONString(event, baseUri: baseUri)
                guard let wireData = wireString.data(using: .utf8),
                      let produced = try JSONSerialization.jsonObject(with: wireData) as? [String: Any]
                else {
                    failures.append("\(file.lastPathComponent): produced data is not a JSON object: \(wireString)")
                    continue
                }
                if let difference = FixtureSupport.diff(expected: expectedData, actual: produced, path: "data") {
                    failures.append("\(file.lastPathComponent): \(difference)")
                }

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

    @Test func accountFixturesPinTheIdentityOfTheEnvelope() throws {
        let accounts = try FixtureSupport.fixtureFiles().map(FixtureSupport.loadFixture)
            .filter { ($0["event"] as? String)?.hasPrefix("account") == true }
        #expect(accounts.count >= 10)
        for fixture in accounts {
            let name = try #require(fixture["name"] as? String)
            let expected = try #require(fixture["expected"] as? [String: Any])
            let h = CoreHarness()
            h.core.track(try FixtureSupport.buildEvent(
                try #require(fixture["event"] as? String), input: try #require(fixture["input"] as? [String: Any])
            ))
            if expected["dropped"] as? Bool == true {
                #expect(h.sender.bodies.isEmpty, "\(name)")
                #expect(h.store[StorageKeys.userId] == nil, "\(name)")
                continue
            }
            let entry = try h.lastEntry()
            let identity = try #require(expected["identity_user_id"] as? String, "\(name)")
            #expect(entry["data"] as? String == expected["data_canonical"] as? String, "\(name)")
            #expect(object(entry, "identity")["user_id"] as? String == identity, "\(name)")
            #expect(h.store[StorageKeys.userId] as? String == identity, "\(name)")
            let email = (expected["data"] as? [String: Any]).flatMap { $0["user"] as? [String: Any] }?["email"] as? String
            #expect(h.store[StorageKeys.email] as? String == email, "\(name)")
        }
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
