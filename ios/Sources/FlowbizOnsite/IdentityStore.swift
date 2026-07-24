import Foundation

/// Persistent identity (SPEC §6): the forever `anonymous_id` plus the
/// `user_id`/`email` pair set by account events and cleared on logout.
///
/// Thread-safe; all state lives in the injected `KeyValueStore`, so
/// instances sharing a store share identity.
final class IdentityStore: @unchecked Sendable {

    private let store: any KeyValueStore
    private let lock = NSLock()

    init(store: any KeyValueStore) {
        self.store = store
    }

    /// Stable anonymous identifier: UUID v4 lowercase, generated on first
    /// access and persisted forever (survives app updates, resets on
    /// uninstall — SPEC §6; no Keychain/backup pinning by design). A corrupt
    /// persisted value (not UUID-shaped per `UUID(uuidString:)`) is silently
    /// replaced with a fresh id; an uppercase one is normalized in place.
    var anonymousId: String {
        lock.lock()
        defer { lock.unlock() }
        if let stored = store.string(forKey: StorageKeys.anonymousId), UUID(uuidString: stored) != nil {
            let normalized = stored.lowercased()
            if normalized != stored {
                store.set(normalized, forKey: StorageKeys.anonymousId)
            }
            return normalized
        }
        let fresh = UUID().uuidString.lowercased() // Foundation UUID is v4
        store.set(fresh, forKey: StorageKeys.anonymousId)
        return fresh
    }

    /// Persisted user id, or nil when signed out.
    var userId: String? {
        lock.lock()
        defer { lock.unlock() }
        return store.string(forKey: StorageKeys.userId)
    }

    /// Persisted user email, or nil when signed out.
    var email: String? {
        lock.lock()
        defer { lock.unlock() }
        return store.string(forKey: StorageKeys.email)
    }

    /// Stores identity from an accountLogin/accountSync payload (SPEC §5
    /// side effect) so subsequent envelopes carry `identity.user_id`.
    func setUser(userId: String, email: String) {
        lock.lock()
        defer { lock.unlock() }
        store.set(userId, forKey: StorageKeys.userId)
        store.set(email, forKey: StorageKeys.email)
    }

    /// Clears user identity (logout support, SPEC §6). `anonymousId` is untouched.
    func clearUser() {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: StorageKeys.userId)
        store.removeValue(forKey: StorageKeys.email)
    }
}
