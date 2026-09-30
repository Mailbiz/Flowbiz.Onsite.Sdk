package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PushTokenPipelineTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun harness() = CoreHarness(temp.newFolder())

    @Test
    fun setPushTokenEmitsSyncEventWithTokenAndPlatform() {
        val harness = harness()
        harness.core.setPushToken("fcm-token-1")
        val entry = harness.lastEntry()
        assertEquals("push.token.sync", entry.getString("event"))
        assertEquals("""{"platform":"android","token":"fcm-token-1"}""", entry.getString("data"))
        assertTrue(entry.getJSONObject("identity").has("session_id"))
        assertEquals("android", entry.getJSONObject("context").getString("platform"))
        assertEquals("fcm-token-1", harness.store.values[StorageKeys.PUSH_TOKEN])
    }

    @Test
    fun identicalTokenWithinDedupWindowIsSuppressed() {
        val harness = harness()
        harness.core.setPushToken("fcm-token-1")
        harness.core.setPushToken("fcm-token-1")
        assertEquals(1, harness.sentEntries().count { it.getString("event") == "push.token.sync" })
        harness.core.setPushToken("fcm-token-2")
        assertEquals(2, harness.sentEntries().count { it.getString("event") == "push.token.sync" })
    }

    @Test
    fun removePushTokenEmitsRemoveWithStoredTokenAndClearsIt() {
        val harness = harness()
        harness.core.setPushToken("fcm-token-1")
        harness.core.removePushToken()
        val entry = harness.lastEntry()
        assertEquals("push.token.remove", entry.getString("event"))
        assertEquals("""{"platform":"android","token":"fcm-token-1"}""", entry.getString("data"))
        assertFalse(harness.store.values.containsKey(StorageKeys.PUSH_TOKEN))
        val sentBefore = harness.sentEntries().size
        harness.core.removePushToken()
        assertEquals(sentBefore, harness.sentEntries().size)
    }

    @Test
    fun removeWithoutStoredTokenIsNoOp() {
        val harness = harness()
        harness.core.removePushToken()
        assertTrue(harness.sentEntries().isEmpty())
    }

    @Test
    fun logoutEmitsRemovalCarryingTheOutgoingUserIdBeforeClearingIdentity() {
        val harness = harness()
        harness.core.track(Event.AccountLogin(User(userId = "u-42", email = "a@b.c")))
        harness.core.setPushToken("fcm-token-1")
        harness.core.logout()
        val removal = harness.sentEntries().last { it.getString("event") == "push.token.remove" }
        assertEquals("u-42", removal.getJSONObject("identity").getString("user_id"))
        assertEquals("""{"platform":"android","token":"fcm-token-1"}""", removal.getString("data"))
        assertFalse(harness.store.values.containsKey(StorageKeys.PUSH_TOKEN))
        assertNull(harness.store.values[StorageKeys.USER_ID])
    }

    @Test
    fun logoutWithoutTokenEmitsNoRemoval() {
        val harness = harness()
        harness.core.track(Event.AccountLogin(User(userId = "u-42", email = "a@b.c")))
        harness.core.logout()
        assertEquals(0, harness.sentEntries().count { it.getString("event") == "push.token.remove" })
    }

    @Test
    fun disabledDropsEventsButStillPersistsAndClearsTheToken() {
        val harness = harness()
        harness.core.setEnabled(false)
        harness.core.setPushToken("fcm-token-1")
        assertTrue(harness.sentEntries().isEmpty())
        assertEquals("fcm-token-1", harness.store.values[StorageKeys.PUSH_TOKEN])
        harness.core.setEnabled(true)
        harness.core.removePushToken()
        val entry = harness.sentEntries().last()
        assertEquals("push.token.remove", entry.getString("event"))
        assertEquals("""{"platform":"android","token":"fcm-token-1"}""", entry.getString("data"))
        assertFalse(harness.store.values.containsKey(StorageKeys.PUSH_TOKEN))
    }

    @Test
    fun removeClearsTheSyncDedupAnchorSoTheSameTokenResyncs() {
        val harness = harness()
        harness.core.setPushToken("fcm-token-1")
        harness.core.removePushToken()
        harness.core.setPushToken("fcm-token-1")
        assertEquals(2, harness.sentEntries().count { it.getString("event") == "push.token.sync" })
    }

    @Test
    fun logoutRemovalAlsoClearsTheSyncDedupAnchor() {
        val harness = harness()
        harness.core.setPushToken("fcm-token-1")
        harness.core.logout()
        harness.core.setPushToken("fcm-token-1")
        assertEquals(2, harness.sentEntries().count { it.getString("event") == "push.token.sync" })
    }

    @Test
    fun reEnableReEmitsSyncForTheStoredToken() {
        val harness = harness()
        harness.core.setEnabled(false)
        harness.core.setPushToken("fcm-token-1")
        assertTrue(harness.sentEntries().isEmpty())
        harness.core.setEnabled(true)
        val syncs = harness.sentEntries().filter { it.getString("event") == "push.token.sync" }
        assertEquals(1, syncs.size)
        assertEquals("""{"platform":"android","token":"fcm-token-1"}""", syncs.single().getString("data"))
    }

    @Test
    fun reEnableWithoutAStoredTokenEmitsNoSync() {
        val harness = harness()
        harness.core.setEnabled(false)
        harness.core.setEnabled(true)
        assertEquals(0, harness.sentEntries().count { it.getString("event") == "push.token.sync" })
    }

    @Test
    fun reEnableReEmitIsSuppressedWhenTheTokenWasAlreadySyncedWithinTheWindow() {
        val harness = harness()
        harness.core.setPushToken("fcm-token-1")
        harness.core.setEnabled(false)
        harness.core.setEnabled(true)
        assertEquals(1, harness.sentEntries().count { it.getString("event") == "push.token.sync" })
    }

    @Test
    fun disabledRemoveStillClearsTheStoredToken() {
        val harness = harness()
        harness.core.setPushToken("fcm-token-1")
        harness.core.setEnabled(false)
        val sentBefore = harness.sentEntries().size
        harness.core.removePushToken()
        assertEquals(sentBefore, harness.sentEntries().size)
        assertFalse(harness.store.values.containsKey(StorageKeys.PUSH_TOKEN))
    }
}
