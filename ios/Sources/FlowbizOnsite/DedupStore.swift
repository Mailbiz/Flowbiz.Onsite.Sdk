import CryptoKit
import Foundation

final class DedupStore: @unchecked Sendable {

    // Web keeps one 25-min TTL renewed by any event; here a fixed 20-min window per wire name.
    static let windowMillis: Int64 = 20 * 60 * 1000

    static let digestKeyPrefix = "dedup_digest_"
    static let atKeyPrefix = "dedup_at_"

    private let store: any KeyValueStore
    private let clock: any Clock

    init(store: any KeyValueStore, clock: any Clock) {
        self.store = store
        self.clock = clock
    }

    func shouldSuppress(wireName: String, dataJSON: String) -> Bool {
        let digest = Self.sha256Hex(dataJSON)
        let digestKey = Self.digestKeyPrefix + wireName
        let atKey = Self.atKeyPrefix + wireName
        // Wall time so the window survives restarts; a clock moved back (elapsed < 0) counts as expired.
        let now = clock.wallMillis()
        if let storedDigest = store.string(forKey: digestKey),
           storedDigest == digest,
           let storedAt = store.int64(forKey: atKey) {
            let elapsed = now - storedAt
            if elapsed >= 0 && elapsed < Self.windowMillis {
                // A duplicate renews the window, like the web EventsState.
                store.set(now, forKey: atKey)
                return true
            }
        }
        store.set(digest, forKey: digestKey)
        store.set(now, forKey: atKey)
        return false
    }

    func clear(wireName: String) {
        store.removeValue(forKey: Self.digestKeyPrefix + wireName)
        store.removeValue(forKey: Self.atKeyPrefix + wireName)
    }

    static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
