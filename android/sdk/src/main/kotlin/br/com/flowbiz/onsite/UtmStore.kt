package br.com.flowbiz.onsite

import org.json.JSONArray

/**
 * The captured UTMs as `[[key, value], …]` (an array: their order is part of
 * `context.utm`), kept until 30 days after the last [save].
 */
internal class UtmStore(
    private val store: KeyValueStore,
    private val clock: Clock,
) {

    fun load(): Map<String, String> {
        val data = store.getString(StorageKeys.UTM_DATA)
        val expiresAt = store.getLong(StorageKeys.UTM_EXPIRES_AT_WALL_MS)
        if (data == null && expiresAt == null) return emptyMap()
        if (data == null || expiresAt == null) return discard("corrupt")
        if (expiresAt <= clock.wallMillis()) return discard("expired")
        return parse(data) ?: discard("corrupt")
    }

    fun save(utms: Map<String, String>) {
        val rows = JSONArray()
        for ((key, value) in utms) rows.put(JSONArray().put(key).put(value))
        store.putString(StorageKeys.UTM_DATA, CanonicalJson.render(rows))
        store.putLong(StorageKeys.UTM_EXPIRES_AT_WALL_MS, clock.wallMillis() + TTL_MS)
    }

    private fun discard(reason: String): Map<String, String> {
        store.remove(StorageKeys.UTM_DATA)
        store.remove(StorageKeys.UTM_EXPIRES_AT_WALL_MS)
        SdkLog.debug("stored utm discarded: $reason")
        return emptyMap()
    }

    private fun parse(data: String): Map<String, String>? = try {
        val rows = JSONArray(data)
        (0 until rows.length()).associate { i ->
            val row = rows.getJSONArray(i)
            require(row.length() == 2)
            // Casts, not getString: Android's org.json turns a number into a string.
            (row.get(0) as String) to (row.get(1) as String)
        }
    } catch (_: Exception) {
        null
    }

    companion object {
        const val TTL_MS = 30L * 24 * 60 * 60 * 1000
    }
}
