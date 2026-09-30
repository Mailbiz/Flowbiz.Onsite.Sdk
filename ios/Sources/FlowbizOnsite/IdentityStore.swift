import Foundation

final class IdentityStore: @unchecked Sendable {

    private let store: any KeyValueStore
    private let lock = NSLock()

    init(store: any KeyValueStore) {
        self.store = store
    }

    // Lives until uninstall: no Keychain or backup pinning, by design.
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
        let fresh = UUID().uuidString.lowercased()
        store.set(fresh, forKey: StorageKeys.anonymousId)
        return fresh
    }

    var userId: String? {
        lock.lock()
        defer { lock.unlock() }
        return store.string(forKey: StorageKeys.userId)
    }

    var email: String? {
        lock.lock()
        defer { lock.unlock() }
        return store.string(forKey: StorageKeys.email)
    }

    func setUser(userId: String, email: String) {
        lock.lock()
        defer { lock.unlock() }
        store.set(userId, forKey: StorageKeys.userId)
        store.set(email, forKey: StorageKeys.email)
    }

    func clearUser() {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: StorageKeys.userId)
        store.removeValue(forKey: StorageKeys.email)
    }
}
