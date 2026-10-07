import Foundation

protocol KeyValueStore {
    func string(forKey key: String) -> String?
    func int(forKey key: String) -> Int?
    func int64(forKey key: String) -> Int64?
    func bool(forKey key: String) -> Bool?
    func set(_ value: String, forKey key: String)
    func set(_ value: Int, forKey key: String)
    func set(_ value: Int64, forKey key: String)
    func set(_ value: Bool, forKey key: String)
    func removeValue(forKey key: String)
}

enum StorageKeys {
    static let anonymousId = "anonymous_id"
    static let userId = "user_id"
    static let email = "email"
    static let sessionId = "session_id"
    static let visitCount = "visit_count"
    static let lastActivityWallMs = "last_activity_wall_ms"
    static let enabled = "enabled"
    static let pushToken = "push_token"
    static let utmData = "utm_data"
    static let utmExpiresAtWallMs = "utm_expires_at_wall_ms"
}
