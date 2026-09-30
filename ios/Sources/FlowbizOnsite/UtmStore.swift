import Foundation

final class UtmStore: @unchecked Sendable {

    static let ttlMillis: Int64 = 30 * 24 * 60 * 60 * 1000

    private let store: any KeyValueStore
    private let clock: any Clock

    init(store: any KeyValueStore, clock: any Clock) {
        self.store = store
        self.clock = clock
    }

    func load() -> UtmLinkParser.Pairs {
        let data = store.string(forKey: StorageKeys.utmData)
        let expiresAt = store.int64(forKey: StorageKeys.utmExpiresAtWallMs)
        guard let data, let expiresAt else { return data == nil && expiresAt == nil ? [] : discard("corrupt") }
        guard expiresAt > clock.wallMillis() else { return discard("expired") }
        guard let rows = try? JSONDecoder().decode([[String]].self, from: Data(data.utf8)),
              rows.allSatisfy({ $0.count == 2 })
        else { return discard("corrupt") }
        return rows.map { (key: $0[0], value: $0[1]) }
    }

    // [key, value] rows, not an object: the order is part of context.utm.
    func save(_ pairs: UtmLinkParser.Pairs) throws {
        store.set(try CanonicalJSON.render(pairs.map { [$0.key, $0.value] }), forKey: StorageKeys.utmData)
        store.set(clock.wallMillis() &+ Self.ttlMillis, forKey: StorageKeys.utmExpiresAtWallMs)
    }

    private func discard(_ reason: String) -> UtmLinkParser.Pairs {
        store.removeValue(forKey: StorageKeys.utmData)
        store.removeValue(forKey: StorageKeys.utmExpiresAtWallMs)
        SdkLog.debug("stored utm discarded: \(reason)")
        return []
    }
}
