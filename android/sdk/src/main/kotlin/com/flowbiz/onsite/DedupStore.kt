package com.flowbiz.onsite

import java.security.MessageDigest

/**
 * SPEC §7 dedup state: per wire event name, a digest of the last accepted
 * `data` payload string plus a wall-clock timestamp, persisted via
 * [KeyValueStore] (dedup must survive process restarts — the window is
 * measured in wall time for the same reason).
 *
 * ## Decisions (flagged for review)
 * - **Renew-on-duplicate**: a suppressed duplicate refreshes the window
 *   timestamp, matching the web `EventsState` which renews the entry's
 *   expiration on duplicate. SPEC §7's "within 20 minutes" alone would read
 *   as a fixed window from the last *send*; "matching current web behavior"
 *   wins — a continuously repeated identical payload stays suppressed until
 *   it pauses for 20 minutes.
 * - **Digest, not the full string**: SHA-256 (platform `java.security`, zero
 *   deps; `CryptoKit` on iOS) bounds the persisted footprint — payloads can
 *   be multi-KB carts. Collision risk is cryptographically negligible.
 * - A wall clock that jumped **backwards** past the stored timestamp makes
 *   the elapsed time negative — treated as expired (send + re-record), so a
 *   clock change can never suppress forever.
 *
 * `page.ping` is exempt (SPEC §7) — the heartbeat bypasses the track
 * pipeline entirely and never reaches this class.
 *
 * Thread-confined to the SDK's serial scheduler (called from the track
 * pipeline only). Never throws.
 */
internal class DedupStore(
    private val store: KeyValueStore,
    private val clock: Clock,
) {

    /**
     * Returns true when an identical payload for [wireName] was accepted (or
     * last duplicated, see renew-on-duplicate above) less than 20 minutes
     * ago. When it returns false, the digest + timestamp are recorded as the
     * new dedup anchor — check and record are one atomic step of the
     * pipeline.
     */
    fun shouldSuppress(wireName: String, dataJson: String): Boolean {
        val digest = sha256Hex(dataJson)
        val digestKey = DIGEST_KEY_PREFIX + wireName
        val atKey = AT_KEY_PREFIX + wireName
        val now = clock.wallMillis()
        val storedDigest = store.getString(digestKey)
        val storedAt = store.getLong(atKey)
        if (digest == storedDigest && storedAt != null) {
            val elapsed = now - storedAt
            if (elapsed in 0 until WINDOW_MS) {
                // Renew-on-duplicate (web EventsState parity, see class doc).
                store.putLong(atKey, now)
                return true
            }
        }
        store.putString(digestKey, digest)
        store.putLong(atKey, now)
        return false
    }

    /**
     * Drops the dedup anchor for [wireName] so the next payload always
     * sends. Used by the token pipeline (SPEC §10.1): emitting
     * `push.token.remove` clears the `push.token.sync` anchor, so a
     * re-registered identical token within the window re-syncs.
     */
    fun clear(wireName: String) {
        store.remove(DIGEST_KEY_PREFIX + wireName)
        store.remove(AT_KEY_PREFIX + wireName)
    }

    companion object {
        /** SPEC §7: 20 min — internal constant, not a config knob. */
        const val WINDOW_MS: Long = 20L * 60L * 1000L

        const val DIGEST_KEY_PREFIX = "dedup_digest_"
        const val AT_KEY_PREFIX = "dedup_at_"

        private const val HEX = "0123456789abcdef"

        /** Lowercase hex SHA-256. Fallback (defensive only) is the raw string. */
        fun sha256Hex(value: String): String = try {
            val bytes = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
            buildString(bytes.size * 2) {
                for (byte in bytes) {
                    append(HEX[(byte.toInt() ushr 4) and 0xF])
                    append(HEX[byte.toInt() and 0xF])
                }
            }
        } catch (_: Throwable) {
            // SHA-256 is mandatory on every JVM/Android runtime; degrading to
            // the raw string keeps dedup correct at a storage-size cost.
            value
        }
    }
}
