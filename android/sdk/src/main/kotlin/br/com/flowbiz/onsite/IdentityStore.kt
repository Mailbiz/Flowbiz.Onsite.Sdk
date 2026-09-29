package br.com.flowbiz.onsite

import java.util.UUID

/**
 * The forever `anonymous_id` plus the `user_id`/`email` pair set by account
 * events and cleared on logout. Thread-safe; all state lives in the store.
 */
internal class IdentityStore(private val store: KeyValueStore) {

    private val lock = Any()

    /**
     * Lowercase UUID v4, generated on first access. Survives app updates and
     * resets on uninstall, like a cleared web cookie. A value that is not
     * UUID-shaped is replaced; an uppercase one is normalized in place.
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

    val userId: String?
        get() = synchronized(lock) { store.getString(StorageKeys.USER_ID) }

    val email: String?
        get() = synchronized(lock) { store.getString(StorageKeys.EMAIL) }

    fun setUser(userId: String, email: String) {
        synchronized(lock) {
            store.putString(StorageKeys.USER_ID, userId)
            store.putString(StorageKeys.EMAIL, email)
        }
    }

    /** `anonymousId` is untouched. */
    fun clearUser() {
        synchronized(lock) {
            store.remove(StorageKeys.USER_ID)
            store.remove(StorageKeys.EMAIL)
        }
    }

    companion object {
        /** Deliberately not v4-strict: only garbage forces regeneration. */
        internal val UUID_SHAPE = Regex(
            "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        )
    }
}
