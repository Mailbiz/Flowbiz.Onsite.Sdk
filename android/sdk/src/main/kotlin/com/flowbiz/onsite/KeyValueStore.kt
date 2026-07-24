package com.flowbiz.onsite

/**
 * Thin abstraction over the platform key-value store (`SharedPreferences`
 * here, `UserDefaults` on iOS) — the SPEC §1 persistence layer for identity,
 * session, the enabled switch and the push token.
 *
 * Contract (SPEC §3): getters return `null` for **missing or corrupt**
 * (wrong-type / unreadable) values so callers degrade to their defaults
 * silently; implementations never throw and writes never block the caller.
 * Implementations must be safe to call from any thread.
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
 * Persistent storage schema. Key names are shared verbatim with the iOS SDK
 * (the containers differ — `flowbiz_onsite_<appId>` preferences file here,
 * same-named `UserDefaults` suite there — but the keys inside are one
 * contract).
 */
internal object StorageKeys {
    /** UUID v4 lowercase, generated on first access, kept forever (SPEC §6). */
    const val ANONYMOUS_ID = "anonymous_id"

    /** Set by accountLogin/accountSync, cleared by logout (SPEC §6). */
    const val USER_ID = "user_id"
    const val EMAIL = "email"

    /** Current session UUID v4 + visit counter (SPEC §6). */
    const val SESSION_ID = "session_id"
    const val VISIT_COUNT = "visit_count"

    /**
     * Wall-clock epoch millis of the last session activity — the restart
     * fallback only; in-process expiry is monotonic (SPEC §6).
     */
    const val LAST_ACTIVITY_WALL_MS = "last_activity_wall_ms"

    /** Opt-out switch (SPEC §12); absent means enabled. */
    const val ENABLED = "enabled"

    /** Last registered push token, kept for logout removal (SPEC §10.1). */
    const val PUSH_TOKEN = "push_token"
}
