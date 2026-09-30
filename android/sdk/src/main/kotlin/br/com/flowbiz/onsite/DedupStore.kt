package br.com.flowbiz.onsite

import java.security.MessageDigest

internal class DedupStore(
    private val store: KeyValueStore,
    private val clock: Clock,
) {

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
                // A duplicate renews the window, like the web `EventsState`.
                store.putLong(atKey, now)
                return true
            }
        }
        store.putString(digestKey, digest)
        store.putLong(atKey, now)
        return false
    }

    fun clear(wireName: String) {
        store.remove(DIGEST_KEY_PREFIX + wireName)
        store.remove(AT_KEY_PREFIX + wireName)
    }

    companion object {
        // Per wire name; the web has one 25-min TTL that any event renews.
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
            value
        }
    }
}
