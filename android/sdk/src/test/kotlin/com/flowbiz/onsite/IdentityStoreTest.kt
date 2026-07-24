package com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** SPEC §6 identity persistence over the injected [KeyValueStore]. */
class IdentityStoreTest {

    private val store = FakeKeyValueStore()
    private val identity = IdentityStore(store)

    private val uuidV4 = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")

    @Test
    fun anonymousIdIsLowercaseUuidV4() {
        assertTrue(uuidV4.matches(identity.anonymousId))
    }

    @Test
    fun anonymousIdGeneratedOnceThenStable() {
        val first = identity.anonymousId
        assertEquals(first, identity.anonymousId)
        // ... and it is the persisted value, not per-instance state.
        assertEquals(first, store.values[StorageKeys.ANONYMOUS_ID])
    }

    @Test
    fun anonymousIdStableAcrossInstancesSharingAStore() {
        val first = identity.anonymousId
        assertEquals(first, IdentityStore(store).anonymousId)
    }

    @Test
    fun distinctStoresGetDistinctAnonymousIds() {
        assertNotEquals(identity.anonymousId, IdentityStore(FakeKeyValueStore()).anonymousId)
    }

    @Test
    fun corruptAnonymousIdSilentlyRegenerated() {
        store.values[StorageKeys.ANONYMOUS_ID] = "definitely-not-a-uuid"
        val regenerated = identity.anonymousId
        assertTrue(uuidV4.matches(regenerated))
        assertEquals(regenerated, store.values[StorageKeys.ANONYMOUS_ID])
    }

    @Test
    fun wrongTypeAnonymousIdSilentlyRegenerated() {
        store.values[StorageKeys.ANONYMOUS_ID] = 12345
        assertTrue(uuidV4.matches(identity.anonymousId))
    }

    @Test
    fun uppercaseAnonymousIdNormalizedInPlace() {
        store.values[StorageKeys.ANONYMOUS_ID] = "A3B1C5D7-1111-4222-8333-444455556666"
        assertEquals("a3b1c5d7-1111-4222-8333-444455556666", identity.anonymousId)
        assertEquals("a3b1c5d7-1111-4222-8333-444455556666", store.values[StorageKeys.ANONYMOUS_ID])
    }

    @Test
    fun userDefaultsToSignedOut() {
        assertNull(identity.userId)
        assertNull(identity.email)
    }

    @Test
    fun setUserPersistsAcrossInstances() {
        identity.setUser("98412", "ana@example.com")
        val reloaded = IdentityStore(store)
        assertEquals("98412", reloaded.userId)
        assertEquals("ana@example.com", reloaded.email)
    }

    @Test
    fun clearUserRemovesUserButKeepsAnonymousId() {
        val anonymous = identity.anonymousId
        identity.setUser("98412", "ana@example.com")
        identity.clearUser()
        assertNull(identity.userId)
        assertNull(identity.email)
        assertEquals(anonymous, identity.anonymousId)
    }
}
