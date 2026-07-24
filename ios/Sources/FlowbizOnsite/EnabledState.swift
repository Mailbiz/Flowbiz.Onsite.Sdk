import Foundation

/// Persisted opt-out switch (SPEC §12): default **true**; a missing or
/// corrupt stored value also reads as enabled. The behavioral consequences —
/// dropping events, stopping the heartbeat, no network — are wired at the
/// facade in Slice 4; this is only the durable switch.
///
/// Thread-safe: stateless over a thread-safe `KeyValueStore`.
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
