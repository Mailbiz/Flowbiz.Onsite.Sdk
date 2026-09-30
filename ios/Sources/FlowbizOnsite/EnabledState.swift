import Foundation

final class EnabledState: @unchecked Sendable {

    private let store: any KeyValueStore

    init(store: any KeyValueStore) {
        self.store = store
    }

    var isEnabled: Bool {
        store.bool(forKey: StorageKeys.enabled) ?? true
    }

    func setEnabled(_ enabled: Bool) {
        store.set(enabled, forKey: StorageKeys.enabled)
    }
}
