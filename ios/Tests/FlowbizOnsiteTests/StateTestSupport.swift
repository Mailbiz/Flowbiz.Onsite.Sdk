// Test doubles for the Slice 2 state components (identity, session,
// enabled, push token): an in-memory KeyValueStore (real UserDefaults would
// leak state between tests and onto the host machine) and a manually-driven
// Clock.
import Foundation
@testable import FlowbizOnsite

/// In-memory `KeyValueStore` mimicking the hardened `UserDefaultsStore`
/// semantics: a value read back as the wrong type degrades to nil, never a
/// throw. `values` is exposed so tests can plant corrupt entries and inspect
/// persistence directly.
final class FakeKeyValueStore: KeyValueStore, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    var values: [String: Any] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }

    subscript(key: String) -> Any? {
        get { values[key] }
        set { values[key] = newValue }
    }

    func string(forKey key: String) -> String? { self[key] as? String }
    func int(forKey key: String) -> Int? { self[key] as? Int }
    func int64(forKey key: String) -> Int64? {
        switch self[key] {
        case let value as Int64: return value
        case let value as Int: return Int64(value) // plist round-trip width erasure
        default: return nil
        }
    }
    func bool(forKey key: String) -> Bool? { self[key] as? Bool }

    func set(_ value: String, forKey key: String) { self[key] = value }
    func set(_ value: Int, forKey key: String) { self[key] = value }
    func set(_ value: Int64, forKey key: String) { self[key] = value }
    func set(_ value: Bool, forKey key: String) { self[key] = value }

    func removeValue(forKey key: String) { self[key] = nil }
}

/// Manually-driven `Clock`; monotonic and wall time are independently mutable.
final class FakeClock: Clock, @unchecked Sendable {

    var monotonic: Int64
    var wall: Int64

    init(monotonic: Int64 = 500_000, wall: Int64 = 1_700_000_000_000 /* 2023-11-14T22:13:20Z */) {
        self.monotonic = monotonic
        self.wall = wall
    }

    func monotonicMillis() -> Int64 { monotonic }
    func wallMillis() -> Int64 { wall }

    /// Real time passing: both clocks advance in lockstep.
    func advance(_ millis: Int64) {
        monotonic += millis
        wall += millis
    }
}

let minuteMs: Int64 = 60_000
