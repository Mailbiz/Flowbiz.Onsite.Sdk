import Foundation

/// Thin abstraction over the platform key-value store (`UserDefaults` here,
/// `SharedPreferences` on Android) — the SPEC §1 persistence layer for
/// identity, session, the enabled switch and the push token.
///
/// Contract (SPEC §3): getters return `nil` for **missing or corrupt**
/// (wrong-type / unreadable) values so callers degrade to their defaults
/// silently; implementations never throw and writes never block the caller.
/// Implementations must be safe to call from any thread.
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

/// Persistent storage schema. Key names are shared verbatim with the Android
/// SDK (the containers differ — `flowbiz_onsite_<appId>` `UserDefaults`
/// suite here, same-named preferences file there — but the keys inside are
/// one contract).
enum StorageKeys {
    /// UUID v4 lowercase, generated on first access, kept forever (SPEC §6).
    static let anonymousId = "anonymous_id"

    /// Set by accountLogin/accountSync, cleared by logout (SPEC §6).
    static let userId = "user_id"
    static let email = "email"

    /// Current session UUID v4 + visit counter (SPEC §6).
    static let sessionId = "session_id"
    static let visitCount = "visit_count"

    /// Wall-clock epoch millis of the last session activity — the restart
    /// fallback only; in-process expiry is monotonic (SPEC §6).
    static let lastActivityWallMs = "last_activity_wall_ms"

    /// Opt-out switch (SPEC §12); absent means enabled.
    static let enabled = "enabled"

    /// Last registered push token, kept for logout removal (SPEC §10.1).
    static let pushToken = "push_token"
}
