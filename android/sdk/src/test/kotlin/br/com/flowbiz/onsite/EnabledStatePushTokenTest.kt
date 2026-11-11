package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class EnabledStatePushTokenTest {

    @get:Rule
    val temp = TemporaryFolder()

    private val store = FakeKeyValueStore()
    private val tokenFile by lazy { File(temp.root, "state/push_token") }

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
        store.values[StorageKeys.ENABLED] = "yes"
        assertTrue(EnabledState(store).isEnabled)
    }

    private fun tokens() = PushTokenStore({ tokenFile }, store)

    @Test
    fun pushTokenDefaultsToNull() {
        assertNull(tokens().token)
    }

    @Test
    fun pushTokenSetPersistsAcrossInstancesInTheFileNeverInTheBackedUpStore() {
        tokens().set("fcm-token-abc123")
        assertEquals("fcm-token-abc123", tokens().token)
        assertEquals("fcm-token-abc123", tokenFile.readText())
        assertTrue(store.values.isEmpty())
    }

    @Test
    fun pushTokenClearRemovesIt() {
        val tokens = tokens()
        tokens.set("fcm-token-abc123")
        tokens.clear()
        assertNull(tokens.token)
        assertNull(tokens().token)
        assertFalse(tokenFile.exists())
    }

    @Test
    fun theTokenOfThePreferencesMovesToTheFileOnce() {
        store.values[StorageKeys.PUSH_TOKEN] = "fcm-token-0.1"
        assertEquals("fcm-token-0.1", tokens().token)
        assertEquals("fcm-token-0.1", tokenFile.readText())
        assertFalse(store.values.containsKey(StorageKeys.PUSH_TOKEN))
    }

    @Test
    fun aTokenInThePreferencesNeverReplacesTheOneInTheFile() {
        tokens().set("fcm-token-this-phone")
        store.values[StorageKeys.PUSH_TOKEN] = "fcm-token-restored"
        assertEquals("fcm-token-this-phone", tokens().token)
        assertFalse(store.values.containsKey(StorageKeys.PUSH_TOKEN))
    }

    @Test
    fun clearingAlsoDropsATokenStillInThePreferences() {
        store.values[StorageKeys.PUSH_TOKEN] = "fcm-token-0.1"
        tokens().clear()
        assertNull(tokens().token)
        assertFalse(store.values.containsKey(StorageKeys.PUSH_TOKEN))
    }

    @Test
    fun anUnusableFileReadsAsNoTokenAndNeverThrows() {
        val tokens = PushTokenStore({ temp.root }, store) // a directory
        tokens.set("fcm-token-abc123")
        assertNull(tokens.token)
        tokens.clear()
    }
}
