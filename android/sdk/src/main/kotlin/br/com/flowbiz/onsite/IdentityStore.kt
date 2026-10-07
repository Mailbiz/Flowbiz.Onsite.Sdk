package br.com.flowbiz.onsite

import java.util.UUID

internal class IdentityStore(private val store: KeyValueStore) {

    private val lock = Any()

    val anonymousId: String
        get() = synchronized(lock) {
            val stored = store.getString(StorageKeys.ANONYMOUS_ID)
            if (stored != null && UUID_SHAPE.matches(stored)) {
                val normalized = stored.lowercase()
                if (normalized != stored) store.putString(StorageKeys.ANONYMOUS_ID, normalized)
                return normalized
            }
            val fresh = UUID.randomUUID().toString()
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

    fun clearUser() {
        synchronized(lock) {
            store.remove(StorageKeys.USER_ID)
            store.remove(StorageKeys.EMAIL)
        }
    }

    companion object {
        // Not v4-strict on purpose: only garbage forces a new anonymous_id.
        internal val UUID_SHAPE = Regex(
            "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        )
    }
}
