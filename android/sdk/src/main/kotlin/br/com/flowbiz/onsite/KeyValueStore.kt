package br.com.flowbiz.onsite

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

internal object StorageKeys {
    const val ANONYMOUS_ID = "anonymous_id"

    const val USER_ID = "user_id"
    const val EMAIL = "email"

    const val SESSION_ID = "session_id"
    const val VISIT_COUNT = "visit_count"

    const val LAST_ACTIVITY_WALL_MS = "last_activity_wall_ms"

    const val ENABLED = "enabled"

    const val PUSH_TOKEN = "push_token"

    const val UTM_DATA = "utm_data"
    const val UTM_EXPIRES_AT_WALL_MS = "utm_expires_at_wall_ms"
}
