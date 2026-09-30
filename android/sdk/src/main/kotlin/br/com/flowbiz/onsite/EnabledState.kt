package br.com.flowbiz.onsite

internal class EnabledState(private val store: KeyValueStore) {

    val isEnabled: Boolean
        get() = store.getBoolean(StorageKeys.ENABLED) ?: true

    fun setEnabled(enabled: Boolean) {
        store.putBoolean(StorageKeys.ENABLED, enabled)
    }
}
