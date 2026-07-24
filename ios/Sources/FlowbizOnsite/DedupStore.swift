import CryptoKit
import Foundation

/// SPEC §7 dedup state: per wire event name, a digest of the last accepted
/// `data` payload string plus a wall-clock timestamp, persisted via
/// `KeyValueStore` (dedup must survive process restarts — the window is
/// measured in wall time for the same reason).
///
/// ## Decisions (flagged for review)
/// - **Renew-on-duplicate**: a suppressed duplicate refreshes the window
///   timestamp, matching the web `EventsState` which renews the entry's
///   expiration on duplicate. SPEC §7's "within 20 minutes" alone would read
///   as a fixed window from the last *send*; "matching current web behavior"
///   wins — a continuously repeated identical payload stays suppressed until
///   it pauses for 20 minutes.
/// - **Digest, not the full string**: SHA-256 (`CryptoKit`, a system
///   framework — zero third-party deps, iOS 13+/macOS 10.15+; Android uses
///   `java.security`) bounds the persisted footprint — payloads can be
///   multi-KB carts. Collision risk is cryptographically negligible.
/// - A wall clock that jumped **backwards** past the stored timestamp makes
///   the elapsed time negative — treated as expired (send + re-record), so a
///   clock change can never suppress forever.
///
/// `page.ping` is exempt (SPEC §7) — the heartbeat bypasses the track
/// pipeline entirely and never reaches this class.
///
/// Thread-confined to the SDK's serial scheduler (called from the track
/// pipeline only). Never throws.
final class DedupStore: @unchecked Sendable {

    /// SPEC §7: 20 min — internal constant, not a config knob.
    static let windowMillis: Int64 = 20 * 60 * 1000

    static let digestKeyPrefix = "dedup_digest_"
    static let atKeyPrefix = "dedup_at_"

    private let store: any KeyValueStore
    private let clock: any Clock

    init(store: any KeyValueStore, clock: any Clock) {
        self.store = store
        self.clock = clock
    }

    /// Returns true when an identical payload for `wireName` was accepted
    /// (or last duplicated, see renew-on-duplicate above) less than
    /// 20 minutes ago. When it returns false, the digest + timestamp are
    /// recorded as the new dedup anchor — check and record are one atomic
    /// step of the pipeline.
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
                // Renew-on-duplicate (web EventsState parity, see class doc).
                store.set(now, forKey: atKey)
                return true
            }
        }
        store.set(digest, forKey: digestKey)
        store.set(now, forKey: atKey)
        return false
    }

    /// Drops the dedup anchor for `wireName` so the next payload always
    /// sends. Used by the token pipeline (SPEC §10.1): emitting
    /// `push.token.remove` clears the `push.token.sync` anchor, so a
    /// re-registered identical token within the window re-syncs.
    func clear(wireName: String) {
        store.removeValue(forKey: Self.digestKeyPrefix + wireName)
        store.removeValue(forKey: Self.atKeyPrefix + wireName)
    }

    /// Lowercase hex SHA-256.
    static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
