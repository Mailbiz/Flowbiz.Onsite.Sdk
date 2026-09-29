package br.com.flowbiz.onsite

/** The last registered push token, kept so `logout()` can emit `push.token.remove` with it. */
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
