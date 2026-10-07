package br.com.flowbiz.onsite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UtmStoreTest {

    private val clock = FakeClock()
    private val kv = FakeKeyValueStore()
    private val store = UtmStore(kv, clock)

    @Test
    fun roundTripKeepsOrderAndValues() {
        val utms = linkedMapOf(
            "utm_campaign" to "a\b\t\n\u000c\rb",
            "utm_source" to "￾",
            "utm_medium" to "promoção 😀",
            "utm_journey" to "lone \ud800",
        )
        store.save(utms)
        assertEquals(utms.toList(), UtmStore(kv, clock).load().toList())
    }

    @Test
    fun saveLastsThirtyDaysAndExpiresExactlyAtExpiry() {
        store.save(mapOf("utm_source" to "flowbiz"))
        assertEquals(clock.wall + 30 * DAY_MS, kv.values[StorageKeys.UTM_EXPIRES_AT_WALL_MS])

        clock.advance(30 * DAY_MS - 1)
        assertEquals(mapOf("utm_source" to "flowbiz"), store.load())
        clock.advance(1)
        assertEquals(emptyMap<String, String>(), store.load())
        assertTrue(kv.values.isEmpty())
    }

    @Test
    fun halfWrittenOrUnparseableDataIsDiscarded() {
        val live = clock.wall + DAY_MS
        val cases = listOf(
            """[["utm_source","a"]]""" to null,
            null to live,
            """[["utm_source","a"]""" to live,
            """[["utm_source"]]""" to live,
        )
        for ((data, expiresAt) in cases) {
            data?.let { kv.values[StorageKeys.UTM_DATA] = it }
            expiresAt?.let { kv.values[StorageKeys.UTM_EXPIRES_AT_WALL_MS] = it }
            assertEquals("$data", emptyMap<String, String>(), store.load())
            assertTrue("$data", kv.values.isEmpty())
        }
    }

    @Test
    fun nothingStoredLoadsEmptyWithoutWriting() {
        val logs = mutableListOf<String>()
        SdkLog.sink = { logs += it }
        try {
            assertEquals(emptyMap<String, String>(), store.load())
        } finally {
            SdkLog.sink = null
        }
        assertTrue(kv.values.isEmpty())
        assertTrue(logs.toString(), logs.isEmpty())
    }
}
