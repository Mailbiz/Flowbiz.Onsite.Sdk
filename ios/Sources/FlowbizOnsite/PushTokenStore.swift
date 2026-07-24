import Foundation

/// Persistence cell for the last registered push token (SPEC §10.1) so
/// `logout()` can emit `push.token.remove` with it. Storage only — the
/// `push.token.sync`/`push.token.remove` events are wired in a later slice.
///
/// Thread-safe: stateless over a thread-safe `KeyValueStore`.
final class PushTokenStore: @unchecked Sendable {

    private let store: any KeyValueStore

    init(store: any KeyValueStore) {
        self.store = store
    }

    var token: String? {
        store.string(forKey: StorageKeys.pushToken)
    }

    func set(_ token: String) {
        store.set(token, forKey: StorageKeys.pushToken)
    }

    func clear() {
        store.removeValue(forKey: StorageKeys.pushToken)
    }
}
