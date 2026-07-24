package com.flowbiz.onsite

import java.util.UUID

/**
 * Persistent identity (SPEC §6): the forever `anonymous_id` plus the
 * `user_id`/`email` pair set by account events and cleared on logout.
 *
 * Thread-safe; all state lives in the injected [KeyValueStore], so instances
 * sharing a store share identity.
 */
internal class IdentityStore(private val store: KeyValueStore) {

    private val lock = Any()

    /**
     * Stable anonymous identifier: UUID v4 lowercase, generated on first
     * access and persisted forever (survives app updates, resets on
     * uninstall — SPEC §6; no Keychain/backup pinning by design). A corrupt
     * persisted value (not UUID-shaped) is silently replaced with a fresh
     * id; an uppercase one is normalized in place.
     */
    val anonymousId: String
        get() = synchronized(lock) {
            val stored = store.getString(StorageKeys.ANONYMOUS_ID)
            if (stored != null && UUID_SHAPE.matches(stored)) {
                val normalized = stored.lowercase()
                if (normalized != stored) store.putString(StorageKeys.ANONYMOUS_ID, normalized)
                return normalized
            }
            val fresh = UUID.randomUUID().toString() // already lowercase v4
            store.putString(StorageKeys.ANONYMOUS_ID, fresh)
            fresh
        }

    /** Persisted user id, or null when signed out. */
    val userId: String?
        get() = synchronized(lock) { store.getString(StorageKeys.USER_ID) }

    /** Persisted user email, or null when signed out. */
    val email: String?
        get() = synchronized(lock) { store.getString(StorageKeys.EMAIL) }

    /**
     * Stores identity from an accountLogin/accountSync payload (SPEC §5 side
     * effect) so subsequent envelopes carry `identity.user_id`.
     */
    fun setUser(userId: String, email: String) {
        synchronized(lock) {
            store.putString(StorageKeys.USER_ID, userId)
            store.putString(StorageKeys.EMAIL, email)
        }
    }

    /** Clears user identity (logout support, SPEC §6). `anonymousId` is untouched. */
    fun clearUser() {
        synchronized(lock) {
            store.remove(StorageKeys.USER_ID)
            store.remove(StorageKeys.EMAIL)
        }
    }

    companion object {
        /**
         * 8-4-4-4-12 hex shape (any case). Deliberately not v4-strict: an id
         * from a future/other generator is still a usable stable identifier,
         * only garbage forces regeneration. Shared with [SessionManager]'s
         * stored-session validation.
         */
        internal val UUID_SHAPE = Regex(
            "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        )
    }
}
