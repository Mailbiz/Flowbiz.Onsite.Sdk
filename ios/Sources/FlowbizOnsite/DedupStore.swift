import CryptoKit
import Foundation

/// Per wire name, a digest of the last accepted `data` (carts can be
/// multi-KB) and when it was seen, in wall time so the window survives
/// restarts. A duplicate renews the window, like the web `EventsState`; a
/// clock moved back past the anchor counts as expired, so it cannot suppress
/// forever. Unlike web's single 25-min TTL renewed by any event, a fixed
/// 20-min window per wire name; `page.ping` never reaches this class.
/// Confined to the SDK's serial queue.
final class DedupStore: @unchecked Sendable {

    static let windowMillis: Int64 = 20 * 60 * 1000

    static let digestKeyPrefix = "dedup_digest_"
    static let atKeyPrefix = "dedup_at_"

    private let store: any KeyValueStore
    private let clock: any Clock

    init(store: any KeyValueStore, clock: any Clock) {
        self.store = store
        self.clock = clock
    }

    /// When false, `dataJSON` becomes the new anchor.
    func shouldSuppress(wireName: String, dataJSON: String) -> Bool {
        let digest = Self.sha256Hex(dataJSON)
        let digestKey = Self.digestKeyPrefix + wireName
        let atKey = Self.atKeyPrefix + wireName
        let now = clock.wallMillis()
        if let storedDigest = store.string(forKey: digestKey),
           storedDigest == digest,
           let storedAt = store.int64(forKey: atKey) {
            let elapsed = now - storedAt
            if elapsed >= 0 && elapsed < Self.windowMillis {
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
