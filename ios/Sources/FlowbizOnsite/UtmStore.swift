import Foundation

/// SPEC §11.1 UTM persistence — the mobile equivalent of web's
/// `tracker_u_<appId>` storage entry (`{ utmData }` with a sliding 30-day
/// expiry). The per-appId container is the `KeyValueStore` itself.
///
/// ## Format (same keys and JSON shape as Android)
/// - `utm_data`: the merged set as a JSON **array of `[key, value]`
///   string pairs**, in merge order. An array — not an object — because
///   the order is part of the wire contract (`context.utm` is web's
///   insertion-ordered `JSON.stringify`) and neither `JSONSerialization`
///   dictionaries nor org.json objects keep key order.
/// - `utm_expires_at_wall_ms`: wall-clock epoch millis (Int64). Wall, not
///   monotonic: the entry must outlive process restarts.
///
/// The bytes differ on purpose: Android escapes every non-ASCII character
/// as `\uXXXX` because SharedPreferences persists as XML 1.0, which cannot
/// carry e.g. a decoded U+FFFE. UserDefaults stores property-list strings
/// that round-trip any scalar except NUL (it truncates there), and the
/// canonical JSON text never holds a raw control character (every
/// U+0000–U+001F is escaped: `\b` `\t` `\n` `\f` `\r` short, `\u00xx`
/// otherwise) — so iOS writes the canonical JSON as is. Both parse to the
/// same pairs.
///
/// ## Semantics (web `storage.ts` parity)
/// - `save` always writes a fresh expiry of now + 30 days — every
///   evaluation with a non-empty merged set slides it.
/// - Valid while `expires − now > 0`: expired at exactly `expires`; an
///   expired entry is removed on read.
/// - `purgeIfExpired` is the read the core does while the SDK is disabled
///   (SPEC §11.1 item 4, §12). It looks at the expiry only, never at the
///   values, and removes an expired entry. It runs at the next startup,
///   foreground or link, so an opted-out set is not kept indefinitely: it
///   stays on disk past its 30 days only until one of those.
/// - Corrupt state (one key missing or wrong-typed, unparseable JSON, not
///   an array of 2-string arrays, a key outside the allowlist, an empty
///   value, a duplicate key, or an empty array — shapes `save` never
///   writes) is removed and reads as empty (SPEC §3). Web keeps an
///   unparseable entry until the next write; the observable result — no
///   UTMs — is the same.
/// - Removal logs `stored utm discarded: expired|corrupt` — the reason
///   only, never the stored data (SPEC §12); same string as Android.
/// - Web's 20 KB compressed-size wipe is not ported (unreachable with real
///   links, SPEC §11.1 step 7).
///
/// Thread-confined to the SDK's serial scheduler (called from the core's
/// UTM evaluation and startup load only). Never throws.
final class UtmStore: @unchecked Sendable {

    /// SPEC §11.1: 30 days — web `thirtyDays * 1000`.
    static let ttlMillis: Int64 = 30 * 24 * 60 * 60 * 1000

    private let store: any KeyValueStore
    private let clock: any Clock

    init(store: any KeyValueStore, clock: any Clock) {
        self.store = store
        self.clock = clock
    }

    /// The stored set in merge order; empty when missing, expired or
    /// corrupt (the latter two are removed).
    func load() -> UtmLinkParser.Pairs {
        let data = store.string(forKey: StorageKeys.utmData)
        let expiresAt = store.int64(forKey: StorageKeys.utmExpiresAtWallMs)
        guard let data, let expiresAt else {
            // Half-written or one key wrong-typed: drop both. Nothing
            // readable at all is the common "never captured" case — no
            // write then (this runs at every startup and foreground); junk
            // of the wrong type under both keys is overwritten by the next
            // save.
            return data != nil || expiresAt != nil ? discard("corrupt") : []
        }
        // `expires − now > 0`, compared without subtracting so a corrupt
        // extreme value can never overflow.
        guard expiresAt > clock.wallMillis() else { return discard("expired") }
        return Self.parse(data) ?? discard("corrupt")
    }

    /// Persists `pairs` with a fresh expiry of now + 30 days.
    func save(_ pairs: UtmLinkParser.Pairs) {
        // Strings only: `render` cannot throw here; the guard is defensive.
        guard let data = try? CanonicalJSON.render(pairs.map { [$0.key, $0.value] }) else { return }
        let (expiresAt, overflow) = clock.wallMillis().addingReportingOverflow(Self.ttlMillis)
        store.set(data, forKey: StorageKeys.utmData)
        store.set(overflow ? Int64.max : expiresAt, forKey: StorageKeys.utmExpiresAtWallMs)
    }

    /// Removes both keys when the stored expiry has passed (`expires <=
    /// now`), reading nothing else: `utm_data` is never read, so a set the
    /// user opted out of is neither parsed nor surfaced. A missing or
    /// wrong-typed expiry is left alone; the next enabled `load` handles it.
    func purgeIfExpired() {
        guard let expiresAt = store.int64(forKey: StorageKeys.utmExpiresAtWallMs),
              expiresAt <= clock.wallMillis()
        else { return }
        _ = discard("expired")
    }

    /// Removes both keys; `reason` is a fixed word, never stored data.
    private func discard(_ reason: StaticString) -> UtmLinkParser.Pairs {
        store.removeValue(forKey: StorageKeys.utmData)
        store.removeValue(forKey: StorageKeys.utmExpiresAtWallMs)
        SdkLog.debug("stored utm discarded: \(reason)")
        return []
    }

    /// `[[key, value], …]` → pairs, or nil when anything is off (see
    /// "Semantics"). Keys are matched against the allowlist by code units.
    private static func parse(_ data: String) -> UtmLinkParser.Pairs? {
        guard let rows = try? JSONDecoder().decode([[String]].self, from: Data(data.utf8)),
              !rows.isEmpty
        else { return nil }
        var pairs: UtmLinkParser.Pairs = []
        for row in rows {
            guard row.count == 2,
                  let key = UtmLinkParser.allowlist.first(where: { $0.utf16.elementsEqual(row[0].utf16) }),
                  !row[1].isEmpty,
                  !pairs.contains(where: { $0.key == key })
            else { return nil }
            pairs.append((key: key, value: row[1]))
        }
        return pairs
    }
}
