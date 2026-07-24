package com.flowbiz.onsite

/**
 * Persistence cell for the last registered push token (SPEC §10.1) so
 * `logout()` can emit `push.token.remove` with it. Storage only — the
 * `push.token.sync`/`push.token.remove` events are wired in a later slice.
 *
 * Thread-safe: stateless over a thread-safe [KeyValueStore].
 */
internal class PushTokenStore(private val store: KeyValueStore) {

    val token: String?
        get() = store.getString(StorageKeys.PUSH_TOKEN)

    fun set(token: String) {
        store.putString(StorageKeys.PUSH_TOKEN, token)
    }

    fun clear() {
        store.remove(StorageKeys.PUSH_TOKEN)
    }
}
