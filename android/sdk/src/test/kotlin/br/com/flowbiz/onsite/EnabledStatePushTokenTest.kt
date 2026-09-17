package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** SPEC §12 enabled switch + SPEC §10.1 push token cell persistence. */
class EnabledStatePushTokenTest {

    private val store = FakeKeyValueStore()

    // --- EnabledState ---

    @Test
    fun enabledDefaultsToTrue() {
        assertTrue(EnabledState(store).isEnabled)
    }

    @Test
    fun setEnabledFalsePersistsAcrossInstances() {
        EnabledState(store).setEnabled(false)
        assertFalse(EnabledState(store).isEnabled)
    }

    @Test
    fun reEnablingPersists() {
        val state = EnabledState(store)
        state.setEnabled(false)
        state.setEnabled(true)
        assertTrue(EnabledState(store).isEnabled)
    }

    @Test
    fun corruptEnabledValueReadsAsEnabled() {
        store.values[StorageKeys.ENABLED] = "yes" // wrong type -> silent default
        assertTrue(EnabledState(store).isEnabled)
    }

    // --- PushTokenStore ---

    @Test
    fun pushTokenDefaultsToNull() {
        assertNull(PushTokenStore(store).token)
    }

    @Test
    fun pushTokenSetPersistsAcrossInstances() {
        PushTokenStore(store).set("fcm-token-abc123")
        assertEquals("fcm-token-abc123", PushTokenStore(store).token)
    }

    @Test
    fun pushTokenClearRemovesIt() {
        val tokens = PushTokenStore(store)
        tokens.set("fcm-token-abc123")
        tokens.clear()
        assertNull(tokens.token)
        assertFalse(store.values.containsKey(StorageKeys.PUSH_TOKEN))
    }

    @Test
    fun corruptPushTokenReadsAsNull() {
        store.values[StorageKeys.PUSH_TOKEN] = 42L
        assertNull(PushTokenStore(store).token)
    }
}
