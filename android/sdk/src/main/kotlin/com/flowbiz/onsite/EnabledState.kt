package com.flowbiz.onsite

/**
 * Persisted opt-out switch (SPEC §12): default **true**; a missing or
 * corrupt stored value also reads as enabled. The behavioral consequences —
 * dropping events, stopping the heartbeat, no network — are wired at the
 * facade in Slice 4; this is only the durable switch.
 *
 * Thread-safe: stateless over a thread-safe [KeyValueStore].
 */
internal class EnabledState(private val store: KeyValueStore) {

    val isEnabled: Boolean
        get() = store.getBoolean(StorageKeys.ENABLED) ?: true

    fun setEnabled(enabled: Boolean) {
        store.putBoolean(StorageKeys.ENABLED, enabled)
    }
}
