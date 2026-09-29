#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct UtmStoreSuite {

    private let clock = FakeClock()
    private let kv = FakeKeyValueStore()
    private var store: UtmStore { UtmStore(store: kv, clock: clock) }

    private var isEmpty: Bool { kv[StorageKeys.utmData] == nil && kv[StorageKeys.utmExpiresAtWallMs] == nil }

    @Test func roundTripKeepsOrderAndValues() throws {
        let pairs: UtmLinkParser.Pairs = [
            (key: "utm_source", value: "\u{8}\t\n\u{C}\r"),
            (key: "utm_campaign", value: "a\"b\\c/\u{FFFE}😀"),
            (key: "utm_medium", value: "email"),
        ]
        try store.save(pairs)
        let loaded = store.load()
        #expect(loaded.map(\.key) == pairs.map(\.key))
        #expect(loaded.map { Array($0.value.utf8) } == pairs.map { Array($0.value.utf8) })
    }

    @Test func saveLastsThirtyDaysAndExpiresExactlyAtExpiry() throws {
        try store.save([(key: "utm_source", value: "flowbiz")])
        #expect(kv[StorageKeys.utmExpiresAtWallMs] as? Int64 == clock.wall + 30 * 24 * 60 * minuteMs)

        clock.advance(UtmStore.ttlMillis - 1)
        #expect(store.load().map(\.value) == ["flowbiz"])
        clock.advance(1)
        #expect(store.load().isEmpty)
        #expect(isEmpty)
    }

    @Test func halfWrittenOrUnparseableDataIsDiscarded() {
        let live = clock.wall + minuteMs
        let cases: [(name: String, data: String?, expiresAt: Int64?)] = [
            ("data only", #"[["utm_source","a"]]"#, nil),
            ("expiry only", nil, live),
            ("truncated", #"[["utm_source","a"]"#, live),
            ("not a pair", #"[["utm_source"]]"#, live),
        ]
        for (name, data, expiresAt) in cases {
            kv[StorageKeys.utmData] = data
            kv[StorageKeys.utmExpiresAtWallMs] = expiresAt
            #expect(store.load().isEmpty, "\(name)")
            #expect(isEmpty, "\(name)")
        }
    }

    @Test func nothingStoredLoadsEmptyWithoutWriting() {
        #expect(store.load().isEmpty)
        #expect(kv.writes.isEmpty)
    }
}
#endif
