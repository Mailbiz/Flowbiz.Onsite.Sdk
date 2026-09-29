package br.com.flowbiz.onsite

/** Persisted opt-out switch; a missing or corrupt stored value reads as enabled. */
internal class EnabledState(private val store: KeyValueStore) {

    val isEnabled: Boolean
        get() = store.getBoolean(StorageKeys.ENABLED) ?: true

    fun setEnabled(enabled: Boolean) {
        store.putBoolean(StorageKeys.ENABLED, enabled)
    }
}
