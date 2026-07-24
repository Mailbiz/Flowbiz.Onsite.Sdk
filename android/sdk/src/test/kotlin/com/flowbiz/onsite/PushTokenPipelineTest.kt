package com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * SPEC §10.1 token relay through the normal pipeline: `push.token.sync` /
 * `push.token.remove` are queued, deduped and session-touched like any
 * event, and `logout()` emits the removal *before* clearing identity so the
 * event carries the outgoing `user_id`.
 */
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
        // Normal envelope machinery: identity/session/context all present.
        assertTrue(entry.getJSONObject("identity").has("session_id"))
        assertEquals("android", entry.getJSONObject("context").getString("platform"))
        // And the token is persisted for a later logout/remove.
        assertEquals("fcm-token-1", harness.store.values[StorageKeys.PUSH_TOKEN])
    }

    @Test
    fun identicalTokenWithinDedupWindowIsSuppressed() {
        val harness = harness()
        harness.core.setPushToken("fcm-token-1")
        harness.core.setPushToken("fcm-token-1")
        assertEquals(1, harness.sentEntries().count { it.getString("event") == "push.token.sync" })
        // A different token is a different payload -> sent.
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
        // Second remove: nothing stored -> no event.
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

    /** Decision under review: removal is emitted BEFORE the identity clear so it carries user_id. */
    @Test
    fun logoutEmitsRemovalCarryingTheOutgoingUserIdBeforeClearingIdentity() {
        val harness = harness()
        harness.core.track(Event.AccountLogin(User(userId = "u-42", email = "a@b.c")))
        harness.core.setPushToken("fcm-token-1")
        harness.core.logout()
        val removal = harness.sentEntries().last { it.getString("event") == "push.token.remove" }
        assertEquals("u-42", removal.getJSONObject("identity").getString("user_id"))
        assertEquals("""{"platform":"android","token":"fcm-token-1"}""", removal.getString("data"))
        // After logout: token gone, identity gone.
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

    /**
     * Decision under review (SPEC §12): while disabled, token events are
     * dropped like any event, but the token cell is still persisted/cleared
     * so a later enable acts on the true registration state.
     */
    @Test
    fun disabledDropsEventsButStillPersistsAndClearsTheToken() {
        val harness = harness()
        harness.core.setEnabled(false)
        harness.core.setPushToken("fcm-token-1")
        assertTrue(harness.sentEntries().isEmpty())
        assertEquals("fcm-token-1", harness.store.values[StorageKeys.PUSH_TOKEN])
        // Re-enabled: the persisted token backs a coherent removal.
        harness.core.setEnabled(true)
        harness.core.removePushToken()
        val entry = harness.sentEntries().last()
        assertEquals("push.token.remove", entry.getString("event"))
        assertEquals("""{"platform":"android","token":"fcm-token-1"}""", entry.getString("data"))
        assertFalse(harness.store.values.containsKey(StorageKeys.PUSH_TOKEN))
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
