import Foundation

/// The last registered push token, kept so `logout()` can remove it.
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
