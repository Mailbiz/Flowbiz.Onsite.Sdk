// SPEC §11.1 UTM persistence: the ordered `utm_data` pair array plus its
// sliding 30-day wall-clock expiry (web `tracker_u_<appId>` storage).
#if canImport(Testing)
import Foundation
import Testing
@testable import FlowbizOnsite

@Suite struct UtmStoreSuite {

    private let store = FakeKeyValueStore()
    private let clock = FakeClock()

    private let pairs: UtmLinkParser.Pairs = [
        (key: "utm_source", value: "flowbiz"),
        (key: "utm_campaign", value: "jornadas|cart|carrinho-abandonado"),
        (key: "utm_medium", value: "e\"mail/\n"),
    ]

    private func rendered(_ pairs: UtmLinkParser.Pairs) -> String {
        UtmLinkParser.render(pairs)
    }

    @Test func thirtyDaysMatchesTheWebStorageTtl() {
        #expect(UtmStore.ttlMillis == 2_592_000_000) // web thirtyDays * 1000
    }

    @Test func missingReadsAsEmpty() {
        #expect(UtmStore(store: store, clock: clock).load().isEmpty)
    }

    @Test func saveRoundTripsInOrderWithAThirtyDayExpiry() {
        let utm = UtmStore(store: store, clock: clock)
        utm.save(pairs)
        #expect(rendered(utm.load()) == rendered(pairs))
        #expect(store[StorageKeys.utmExpiresAtWallMs] as? Int64 == clock.wall + UtmStore.ttlMillis)
        // Wire format shared with Android: an ordered array of [key, value].
        #expect(
            store[StorageKeys.utmData] as? String
                == #"[["utm_source","flowbiz"],["utm_campaign","jornadas|cart|carrinho-abandonado"],["utm_medium","e\"mail/\n"]]"#
        )
    }

    @Test func storageKeysAreTheSharedWireNames() {
        #expect(StorageKeys.utmData == "utm_data")
        #expect(StorageKeys.utmExpiresAtWallMs == "utm_expires_at_wall_ms")
    }

    @Test func persistsAcrossStoreInstances() {
        UtmStore(store: store, clock: clock).save(pairs)
        #expect(rendered(UtmStore(store: store, clock: clock).load()) == rendered(pairs))
    }

    @Test func everySaveSlidesTheExpiry() {
        let utm = UtmStore(store: store, clock: clock)
        utm.save(pairs)
        clock.advance(10 * 24 * 60 * minuteMs)
        utm.save(pairs)
        #expect(store[StorageKeys.utmExpiresAtWallMs] as? Int64 == clock.wall + UtmStore.ttlMillis)
    }

    /// Web validity is `expires − now > 0`: still valid one millisecond
    /// before, expired at exactly `expires` — and an expired entry is
    /// removed on read.
    @Test func validUntilOneMillisecondBeforeExpiryThenRemoved() {
        let utm = UtmStore(store: store, clock: clock)
        utm.save(pairs)
        clock.advance(UtmStore.ttlMillis - 1)
        #expect(utm.load().count == 3)

        clock.advance(1)
        #expect(utm.load().isEmpty)
        #expect(store[StorageKeys.utmData] == nil)
        #expect(store[StorageKeys.utmExpiresAtWallMs] == nil)
    }

    @Test func extremeStoredExpiryNeverTraps() {
        store[StorageKeys.utmData] = #"[["utm_source","a"]]"#
        store[StorageKeys.utmExpiresAtWallMs] = Int64.min
        #expect(UtmStore(store: store, clock: clock).load().isEmpty)
        #expect(store[StorageKeys.utmData] == nil)

        clock.wall = Int64.max
        UtmStore(store: store, clock: clock).save(pairs) // saturates, never overflows
        #expect(store[StorageKeys.utmExpiresAtWallMs] as? Int64 == Int64.max)
    }

    /// SPEC §3: corrupt persisted state is discarded silently — both keys
    /// go, and the read degrades to empty.
    @Test func corruptEntriesRemoveBothKeys() {
        let validData = #"[["utm_source","a"]]"#
        let validExpiry = clock.wall + minuteMs
        let corruptions: [(String, Any?, Any?)] = [
            ("data missing", nil, validExpiry),
            ("expiry missing", validData, nil),
            ("data wrong type", 42, validExpiry),
            ("expiry wrong type", validData, "tomorrow"),
            ("unparseable", "[[\"utm_source\",", validExpiry),
            ("not an array", #"{"utm_source":"a"}"#, validExpiry),
            ("element not an array", #"["utm_source"]"#, validExpiry),
            ("element too short", #"[["utm_source"]]"#, validExpiry),
            ("element too long", #"[["utm_source","a","b"]]"#, validExpiry),
            ("non-string value", #"[["utm_source",1]]"#, validExpiry),
            ("null value", #"[["utm_source",null]]"#, validExpiry),
            ("key not allowlisted", #"[["utm_term","a"]]"#, validExpiry),
            ("flow params never stored", #"[["utm_flow_params","a|b"]]"#, validExpiry),
            ("key case differs", #"[["UTM_SOURCE","a"]]"#, validExpiry),
            ("empty value", #"[["utm_source",""]]"#, validExpiry),
            ("duplicate key", #"[["utm_source","a"],["utm_source","b"]]"#, validExpiry),
            // Never written (an empty merge writes nothing), so as corrupt
            // as the rest — and dropped at once, as on Android.
            ("empty array", "[]", validExpiry),
        ]
        for (name, data, expiry) in corruptions {
            let store = FakeKeyValueStore()
            store[StorageKeys.utmData] = data
            store[StorageKeys.utmExpiresAtWallMs] = expiry
            #expect(UtmStore(store: store, clock: clock).load().isEmpty, "\(name)")
            #expect(store[StorageKeys.utmData] == nil, "\(name): utm_data kept")
            #expect(store[StorageKeys.utmExpiresAtWallMs] == nil, "\(name): expiry kept")
        }
    }

    /// SPEC §11.1 item 4 / §12: the purge run while disabled reads nothing
    /// but the expiry. An expired entry loses both keys whatever
    /// `utm_data` holds. A live entry, or one without a readable expiry,
    /// is left as is even when `utm_data` is corrupt. `load` would remove
    /// that one, which proves the purge never reads the values.
    @Test func purgeIfExpiredReadsOnlyTheExpiry() {
        let validData = #"[["utm_source","a"]]"#
        let cases: [(name: String, data: Any?, expiry: Any?, removed: Bool)] = [
            ("expired", validData, clock.wall - 1, true),
            ("expired at exactly now", validData, clock.wall, true),
            ("expired, corrupt data", "{not json", clock.wall - 1, true),
            ("expired, data wrong type", 42, clock.wall - 1, true),
            ("expired, data missing", nil, clock.wall - 1, true),
            ("extreme past expiry", validData, Int64.min, true),
            ("live", validData, clock.wall + 1, false),
            ("live, corrupt data", "{not json", clock.wall + 1, false),
            ("expiry missing", "{not json", nil, false),
            ("expiry wrong type", validData, "yesterday", false),
            ("nothing stored", nil, nil, false),
        ]
        func describe(_ value: Any?) -> String { value.map { "\($0)" } ?? "nil" }
        for (name, data, expiry, removed) in cases {
            let store = FakeKeyValueStore()
            store[StorageKeys.utmData] = data
            store[StorageKeys.utmExpiresAtWallMs] = expiry
            UtmStore(store: store, clock: clock).purgeIfExpired()
            if removed {
                #expect(store[StorageKeys.utmData] == nil, "\(name): utm_data kept")
                #expect(store[StorageKeys.utmExpiresAtWallMs] == nil, "\(name): expiry kept")
            } else {
                #expect(describe(store[StorageKeys.utmData]) == describe(data), "\(name): utm_data touched")
                #expect(describe(store[StorageKeys.utmExpiresAtWallMs]) == describe(expiry), "\(name): expiry touched")
            }
        }
    }
}
#endif
