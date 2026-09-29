package br.com.flowbiz.onsite

/**
 * Platform key-value store seam. Getters return `null` for **missing or
 * corrupt** (wrong-type / unreadable) values so callers degrade to their
 * defaults silently; implementations never throw, writes never block the
 * caller, and every call is safe from any thread.
 */
internal interface KeyValueStore {
    fun getString(key: String): String?
    fun getInt(key: String): Int?
    fun getLong(key: String): Long?
    fun getBoolean(key: String): Boolean?
    fun putString(key: String, value: String)
    fun putInt(key: String, value: Int)
    fun putLong(key: String, value: Long)
    fun putBoolean(key: String, value: Boolean)
    fun remove(key: String)
}

/**
 * Key names are one contract with the iOS SDK; only the container differs
 * (`flowbiz_onsite_<appId>` preferences here, a same-named `UserDefaults`
 * suite there).
 */
internal object StorageKeys {
    const val ANONYMOUS_ID = "anonymous_id"

    const val USER_ID = "user_id"
    const val EMAIL = "email"

    const val SESSION_ID = "session_id"
    const val VISIT_COUNT = "visit_count"

    /** Restart fallback only: in-process session expiry is monotonic. */
    const val LAST_ACTIVITY_WALL_MS = "last_activity_wall_ms"

    /** Absent means enabled. */
    const val ENABLED = "enabled"

    /** Kept so logout can emit its removal. */
    const val PUSH_TOKEN = "push_token"

    /** Captured campaign UTMs and their wall-clock expiry ([UtmStore]). */
    const val UTM_DATA = "utm_data"
    const val UTM_EXPIRES_AT_WALL_MS = "utm_expires_at_wall_ms"
}
