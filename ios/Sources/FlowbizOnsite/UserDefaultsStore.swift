import Foundation

/// `KeyValueStore` over `UserDefaults`, suite `flowbiz_onsite_<appId>`
/// (appId-scoped so distinct tenants in one host app never collide, and so
/// the SDK never touches the host app's standard defaults domain). The
/// suite name intentionally matches the Android preferences file name —
/// one storage schema, see `StorageKeys`.
///
/// SPEC §3 hardening: reads go through `object(forKey:)` with conditional
/// casts — a value persisted with a different type degrades to `nil`, never
/// a crash. Numeric reads accept any exactly-representable `NSNumber`
/// (UserDefaults plists don't preserve Swift integer widths). Writes are
/// synchronous in-memory with async disk persistence — never block the
/// caller. `UserDefaults` itself is thread-safe.
///
/// If the suite cannot be created (`UserDefaults(suiteName:)` returns nil
/// for reserved names — cannot happen for our fixed prefix, but SPEC §3
/// forbids assuming), it falls back to `.standard` with prefixed keys.
final class UserDefaultsStore: KeyValueStore, @unchecked Sendable {

    private let defaults: UserDefaults
    private let prefix: String

    init(appId: String) {
        let suiteName = "flowbiz_onsite_\(appId)"
        if let suite = UserDefaults(suiteName: suiteName) {
            defaults = suite
            prefix = ""
        } else {
            defaults = .standard
            prefix = suiteName + "."
        }
    }

    func string(forKey key: String) -> String? {
        defaults.object(forKey: prefix + key) as? String
    }

    func int(forKey key: String) -> Int? {
        (defaults.object(forKey: prefix + key) as? NSNumber).flatMap { Int(exactly: $0) }
    }

    func int64(forKey key: String) -> Int64? {
        (defaults.object(forKey: prefix + key) as? NSNumber).flatMap { Int64(exactly: $0) }
    }

    func bool(forKey key: String) -> Bool? {
        defaults.object(forKey: prefix + key) as? Bool
    }

    func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: prefix + key)
    }

    func set(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: prefix + key)
    }

    func set(_ value: Int64, forKey key: String) {
        defaults.set(NSNumber(value: value), forKey: prefix + key)
    }

    func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: prefix + key)
    }

    func removeValue(forKey key: String) {
        defaults.removeObject(forKey: prefix + key)
    }
}
