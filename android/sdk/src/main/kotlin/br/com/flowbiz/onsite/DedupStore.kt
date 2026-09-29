package br.com.flowbiz.onsite

import java.security.MessageDigest

/**
 * Per wire name, a digest of the last accepted `data` (carts can be
 * multi-KB) and when it was seen, in wall time so the window survives
 * restarts. A duplicate renews the window, like the web `EventsState`; a
 * clock moved back past the anchor counts as expired, so it cannot suppress
 * forever. Unlike web's single 25-min TTL renewed by any event, a fixed
 * 20-min window per wire name; `page.ping` never reaches this class.
 * Confined to the SDK's serial scheduler thread. Never throws.
 */
internal class DedupStore(
    private val store: KeyValueStore,
    private val clock: Clock,
) {

    /** True for an identical payload within the window; otherwise records it as the new anchor. */
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
                store.putLong(atKey, now)
                return true
            }
        }
        store.putString(digestKey, digest)
        store.putLong(atKey, now)
        return false
    }

    /** Drops the anchor for [wireName], so its next payload always sends. */
    fun clear(wireName: String) {
        store.remove(DIGEST_KEY_PREFIX + wireName)
        store.remove(AT_KEY_PREFIX + wireName)
    }

    companion object {
        const val WINDOW_MS: Long = 20L * 60L * 1000L

        const val DIGEST_KEY_PREFIX = "dedup_digest_"
        const val AT_KEY_PREFIX = "dedup_at_"

        private const val HEX = "0123456789abcdef"

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
