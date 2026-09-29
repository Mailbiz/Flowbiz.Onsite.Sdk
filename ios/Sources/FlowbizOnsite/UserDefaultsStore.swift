import Foundation

/// One suite per appId, named like the Android preferences file, so tenants
/// never collide and the host's standard defaults stay untouched. Numbers
/// read as any exactly-representable `NSNumber`: plists drop Swift integer
/// widths.
final class UserDefaultsStore: KeyValueStore, @unchecked Sendable {

    private let defaults: UserDefaults
    private let prefix: String

    init(appId: String) {
        let suiteName = "flowbiz_onsite_\(appId)"
        if let suite = UserDefaults(suiteName: suiteName) {
            defaults = suite
            prefix = ""
        } else { // nil only for reserved suite names
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
